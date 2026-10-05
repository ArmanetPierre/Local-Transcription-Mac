import Foundation

enum PythonBridgeError: LocalizedError {
    case processExited(code: Int32, stderr: String)
    case pythonNotFound(path: String)
    case scriptNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .processExited(let code, let stderr):
            String(localized: "Python process exited (code \(code)): \(stderr)")
        case .pythonNotFound(let path):
            String(localized: "Python not found: \(path)")
        case .scriptNotFound(let path):
            String(localized: "Script not found: \(path)")
        }
    }
}

@Observable
final class PythonBridge {
    var isRunning = false
    /// Sans aucun message du moteur pendant ce delai, il est considere comme bloque
    static let inactivityTimeout: TimeInterval = 30 * 60
    var currentStep = ""
    var progressPercent: Double = 0

    private var process: Process?

    // Paths configurables — default to managed Application Support locations
    static let defaultPythonPath: String = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Voxa/.venv/bin/python")
            .path
    }()

    static let defaultScriptPath: String = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Voxa/Scripts/transcribe_bridge.py")
            .path
    }()

    func transcribe(
        audioPath: String,
        model: WhisperModel = .largeV3Turbo,
        language: String? = nil,
        numSpeakers: Int? = nil,
        minSpeakers: Int? = nil,
        maxSpeakers: Int? = nil,
        diarize: Bool = true,
        hfToken: String,
        pythonPath: String = PythonBridge.defaultPythonPath,
        scriptPath: String = PythonBridge.defaultScriptPath,
        engine: TranscriptionEngine = .python
    ) -> AsyncThrowingStream<PythonMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let process = Process()
                self.process = process
                var arguments: [String]

                switch engine {
                case .python:
                    // Validate paths
                    guard FileManager.default.fileExists(atPath: pythonPath) else {
                        continuation.finish(throwing: PythonBridgeError.pythonNotFound(path: pythonPath))
                        return
                    }
                    guard FileManager.default.fileExists(atPath: scriptPath) else {
                        continuation.finish(throwing: PythonBridgeError.scriptNotFound(path: scriptPath))
                        return
                    }
                    process.executableURL = URL(fileURLWithPath: pythonPath)
                    arguments = [
                        "-u", // Unbuffered stdout
                        scriptPath,
                        "--audio", audioPath,
                        "--model", model.rawValue,
                        "--json-protocol",
                        "--embeddings-file", SpeakerEmbeddingStore.embeddingsFilePath,
                    ]
                case .native:
                    // Moteur natif embarque (WhisperKit + SpeakerKit), meme protocole JSON Lines
                    guard let executable = NativeEngineSupport.executableURL else {
                        continuation.finish(throwing: PythonBridgeError.scriptNotFound(path: "voxa-engine"))
                        return
                    }
                    process.executableURL = executable
                    arguments = [
                        "--audio", audioPath,
                        "--json-protocol",
                        "--embeddings-file", SpeakerEmbeddingStore.embeddingsFilePath,
                        "--models-dir", NativeEngineSupport.modelsDirectory.path,
                    ]
                }
                if let lang = language {
                    arguments += ["--language", lang]
                }
                if let n = numSpeakers {
                    arguments += ["--num-speakers", String(n)]
                }
                if let min = minSpeakers {
                    arguments += ["--min-speakers", String(min)]
                }
                if let max = maxSpeakers {
                    arguments += ["--max-speakers", String(max)]
                }
                if !diarize {
                    arguments.append("--no-diarize")
                }

                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
                env["PYTHONUNBUFFERED"] = "1"
                // Jeton par variable d'environnement : un argument serait visible de tous via `ps`
                if !hfToken.isEmpty {
                    env["HF_TOKEN"] = hfToken
                }
                // Desactiver la validation Metal (activee par Xcode en Debug)
                // pour eviter les SIGABRT sur certains shaders pyannote/MPS
                env["METAL_DEVICE_WRAPPER_TYPE"] = "0"
                // Add Voxa bin directory and common paths so ffmpeg is discoverable
                let voxaBin = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first!.appendingPathComponent("Voxa/bin").path
                let extraPaths = "\(voxaBin):/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
                if let currentPath = env["PATH"] {
                    env["PATH"] = extraPaths + ":" + currentPath
                } else {
                    env["PATH"] = extraPaths + ":/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let reader = JSONLineReader { message in continuation.yield(message) }

                await MainActor.run {
                    self.isRunning = true
                    self.currentStep = ""
                    self.progressPercent = 0
                }

                // Fin = processus termine ET sortie entierement lue (le resultat final est
                // ecrit juste avant la sortie). Les lectures restent dans l'ordre : tout passe
                // par le gestionnaire de lecture, jusqu'a la fin de fichier.
                let completion = BridgeCompletion()

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        completion.stdoutDidClose()
                    } else {
                        reader.feed(data)
                    }
                }

                // Lire stderr au fil de l'eau : si personne ne le vide, le tampon du
                // pipe (64 Ko) se remplit et Python se bloque en ecrivant ses logs.
                // On ne garde que la fin, utile pour le message d'erreur.
                let stderrTail = StderrTail()
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        stderrTail.append(data)
                    }
                }

                // Moteur bloque (telechargement, MPS...) : sans message pendant trop longtemps,
                // on l'arrete plutot que de bloquer toute la file indefiniment
                let watchdog = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        if Date().timeIntervalSince(reader.lastActivity) > Self.inactivityTimeout, process.isRunning {
                            print("[PythonBridge] Aucun message depuis \(Int(Self.inactivityTimeout / 60)) min : arret du moteur")
                            reader.timedOut = true
                            process.terminate()
                            return
                        }
                    }
                }

                completion.onComplete = { [weak self] status in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    reader.flush()

                    Task { @MainActor in
                        self?.isRunning = false
                    }

                    if reader.timedOut {
                        continuation.finish(throwing: PythonBridgeError.processExited(
                            code: status,
                            stderr: "Le moteur ne repondait plus (aucun message pendant \(Int(Self.inactivityTimeout / 60)) min)."))
                    } else if status != 0 {
                        let errStr = stderrTail.text.isEmpty ? "Erreur inconnue" : stderrTail.text
                        continuation.finish(throwing: PythonBridgeError.processExited(
                            code: status, stderr: errStr))
                    } else {
                        continuation.finish()
                    }
                }

                process.terminationHandler = { proc in
                    watchdog.cancel()
                    completion.processDidExit(status: proc.terminationStatus)
                    // Un processus enfant peut garder la sortie ouverte : pas plus de 5 s d'attente
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        completion.stdoutDidClose()
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    if process.isRunning { process.terminate() }
                }

                do {
                    try process.run()
                } catch {
                    await MainActor.run {
                        self.isRunning = false
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancel() {
        process?.terminate()
    }
}

/// Termine le flux une seule fois, quand le processus est sorti et que sa sortie est lue.
final class BridgeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var stdoutClosed = false
    private var done = false
    var onComplete: ((Int32) -> Void)?

    func processDidExit(status: Int32) {
        lock.withLock { self.status = status }
        completeIfReady()
    }

    func stdoutDidClose() {
        lock.withLock { stdoutClosed = true }
        completeIfReady()
    }

    private func completeIfReady() {
        let ready: Int32? = lock.withLock {
            guard !done, stdoutClosed, let status else { return nil }
            done = true
            return status
        }
        if let ready { onComplete?(ready) }
    }
}

/// Decoupe la sortie du moteur en lignes JSON. Travaille sur des octets : un morceau
/// coupe au milieu d'un caractere accentue ne fait pas perdre la ligne.
final class JSONLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let decoder = JSONDecoder()
    private let onMessage: (PythonMessage) -> Void
    private var _lastActivity = Date()
    var timedOut = false

    init(onMessage: @escaping (PythonMessage) -> Void) {
        self.onMessage = onMessage
    }

    var lastActivity: Date { lock.withLock { _lastActivity } }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            _lastActivity = Date()
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                emit(Data(line))
            }
        }
    }

    /// Derniere ligne sans retour a la ligne final
    func flush() {
        lock.withLock {
            if !pending.isEmpty { emit(pending) }
            pending = Data()
        }
    }

    private func emit(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let message = try? decoder.decode(PythonMessage.self, from: Data(text.utf8)) {
            onMessage(message)
        } else {
            // Ligne non-JSON (log qui fuite sur stdout)
            onMessage(.log(LogMessage(level: "debug", message: text)))
        }
    }
}

/// Fin de la sortie d'erreur d'un processus, remplie depuis un thread de lecture.
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes: Int

    init(maxBytes: Int = 64 * 1024) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > maxBytes {
            data = data.suffix(maxBytes)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

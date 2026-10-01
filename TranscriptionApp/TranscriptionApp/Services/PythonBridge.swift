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

                let decoder = JSONDecoder()
                var buffer = ""

                await MainActor.run {
                    self.isRunning = true
                    self.currentStep = ""
                    self.progressPercent = 0
                }

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    guard let str = String(data: data, encoding: .utf8) else { return }

                    buffer += str
                    let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)

                    // Garder la derniere partie incomplete dans le buffer
                    if buffer.hasSuffix("\n") {
                        buffer = ""
                    } else if let last = lines.last {
                        buffer = String(last)
                    }

                    let completeLines = buffer.isEmpty ? lines : lines.dropLast()

                    for line in completeLines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        guard let lineData = trimmed.data(using: .utf8) else { continue }

                        do {
                            let message = try decoder.decode(PythonMessage.self, from: lineData)
                            continuation.yield(message)
                        } catch {
                            // Ligne non-JSON (log stderr qui fuite sur stdout)
                            continuation.yield(.log(LogMessage(level: "debug", message: trimmed)))
                        }
                    }
                }

                // Lire stderr au fil de l'eau : si personne ne le vide, le tampon du
                // pipe (64 Ko) se remplit et Python se bloque en ecrivant ses logs.
                // On ne garde que la fin, utile pour le message d'erreur.
                let stderrTail = StderrTail()
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    stderrTail.append(handle.availableData)
                }

                process.terminationHandler = { [weak self] proc in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    stderrTail.append(stderr.fileHandleForReading.readDataToEndOfFile())

                    Task { @MainActor in
                        self?.isRunning = false
                    }

                    if proc.terminationStatus != 0 {
                        let errStr = stderrTail.text.isEmpty ? "Erreur inconnue" : stderrTail.text
                        continuation.finish(throwing: PythonBridgeError.processExited(
                            code: proc.terminationStatus, stderr: errStr))
                    } else {
                        continuation.finish()
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

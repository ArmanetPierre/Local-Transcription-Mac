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
        scriptPath: String = PythonBridge.defaultScriptPath
    ) -> AsyncThrowingStream<PythonMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Validate paths
                guard FileManager.default.fileExists(atPath: pythonPath) else {
                    continuation.finish(throwing: PythonBridgeError.pythonNotFound(path: pythonPath))
                    return
                }
                guard FileManager.default.fileExists(atPath: scriptPath) else {
                    continuation.finish(throwing: PythonBridgeError.scriptNotFound(path: scriptPath))
                    return
                }

                let process = Process()
                self.process = process
                process.executableURL = URL(fileURLWithPath: pythonPath)

                var arguments = [
                    "-u", // Unbuffered stdout
                    scriptPath,
                    "--audio", audioPath,
                    "--model", model.rawValue,
                    "--json-protocol",
                    "--hf-token", hfToken,
                    "--embeddings-file", SpeakerEmbeddingStore.embeddingsFilePath,
                ]
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

                process.terminationHandler = { [weak self] proc in
                    stdout.fileHandleForReading.readabilityHandler = nil

                    Task { @MainActor in
                        self?.isRunning = false
                    }

                    if proc.terminationStatus != 0 {
                        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8) ?? "Erreur inconnue"
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

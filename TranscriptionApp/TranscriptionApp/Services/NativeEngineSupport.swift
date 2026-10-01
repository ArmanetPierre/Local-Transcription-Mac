import Foundation

/// Moteur de transcription utilise par l'app
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    /// Whisper (MLX) + pyannote dans le venv Python : moteur eprouve
    case python
    /// WhisperKit + SpeakerKit (Core ML), sans Python : experimental
    case native

    var id: String { rawValue }

    static let defaultsKey = "transcription_engine"

    static var selected: TranscriptionEngine {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? TranscriptionEngine.python.rawValue
        let engine = TranscriptionEngine(rawValue: raw) ?? .python
        // Le moteur natif n'est utilise qu'une fois ses modeles prets
        return engine == .native && !NativeEngineSupport.isPrepared ? .python : engine
    }

    var displayName: String {
        switch self {
        case .python: String(localized: "Python (stable)")
        case .native: String(localized: "Native (experimental)")
        }
    }
}

/// Moteur natif embarque : executable voxa-engine (Packages/VoxaEngine) et ses modeles.
@Observable
final class NativeEngineSupport {
    static let shared = NativeEngineSupport()

    var isPreparing = false
    var lastMessage: String?
    var error: String?

    static var executableURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "voxa-engine")
    }

    /// Dossier stable : Core ML prepare les modeles pour la puce une fois par emplacement
    static var modelsDirectory: URL {
        DependencyManager.appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    private static var preparedMarker: URL {
        modelsDirectory.appendingPathComponent(".prepared")
    }

    /// Identite de l'executable embarque : Core ML refait la preparation des
    /// modeles (plusieurs minutes) quand l'executable change, donc a chaque mise a jour.
    static var engineIdentity: String? {
        guard let url = executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(build)-\(size)-\(Int(date))"
    }

    /// Modeles prets pour CETTE version du moteur
    static var isPrepared: Bool {
        guard let identity = engineIdentity,
              let data = FileManager.default.contents(atPath: preparedMarker.path) else { return false }
        return String(decoding: data, as: UTF8.self) == identity
    }

    /// Le moteur natif est choisi mais pas (ou plus) prepare, par exemple apres une
    /// mise a jour : on relance la preparation en arriere-plan. En attendant, le
    /// moteur Python est utilise.
    @MainActor
    func prepareIfNeeded() {
        let chosen = UserDefaults.standard.string(forKey: TranscriptionEngine.defaultsKey)
        guard chosen == TranscriptionEngine.native.rawValue, !Self.isPrepared, !isPreparing else { return }
        print("[NativeEngine] Preparation automatique des modeles (nouvelle version du moteur)")
        Task { await prepare() }
    }

    /// Telecharge (~1,6 Go) et prepare les modeles. Plusieurs minutes la premiere fois.
    @MainActor
    func prepare() async {
        guard !isPreparing, let executable = Self.executableURL else {
            if Self.executableURL == nil { error = "voxa-engine introuvable dans l'app" }
            return
        }
        isPreparing = true
        error = nil
        lastMessage = nil
        defer { isPreparing = false }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--prepare", "--models-dir", Self.modelsDirectory.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let status: Int32 = await withCheckedContinuation { continuation in
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let message = json["message"] as? String else { continue }
                    Task { @MainActor in
                        if json["type"] as? String == "error" { self?.error = message } else { self?.lastMessage = message }
                    }
                }
            }
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }

        if status == 0 {
            FileManager.default.createFile(atPath: Self.preparedMarker.path, contents: Data((Self.engineIdentity ?? "").utf8))
        } else if error == nil {
            error = String(localized: "Preparing the native engine failed.")
        }
    }
}

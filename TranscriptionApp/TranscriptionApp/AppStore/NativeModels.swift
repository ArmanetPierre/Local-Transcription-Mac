import Foundation
import VoxaEngine

/// Version App Store : modeles du moteur natif (WhisperKit + SpeakerKit), dans le
/// meme processus que l'app (pas de Python, pas d'executable externe).
///
/// Core ML prepare les modeles pour la puce au premier chargement (quelques minutes),
/// et recommence quand l'app change (mise a jour) : la preparation est memorisee
/// pour une version precise de l'app.
@Observable
final class NativeModels {
    static let shared = NativeModels()

    let engine = NativeEngine(modelsDirectory: AppPaths.modelsDirectory)

    var isPreparing = false
    var statusMessage: String?
    var error: String?
    var isPrepared = NativeModels.markerIsCurrent

    private var preparation: Task<Void, Error>?

    private static var marker: URL {
        AppPaths.modelsDirectory.appendingPathComponent(".prepared")
    }

    /// Identite de l'app : version + date de l'executable (change a chaque mise a jour)
    private static var identity: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?")-\(info?["CFBundleVersion"] ?? "?")"
        let executable = Bundle.main.executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        return "\(version)-\(Int(executable?.timeIntervalSince1970 ?? 0))"
    }

    private static var markerIsCurrent: Bool {
        guard let data = FileManager.default.contents(atPath: marker.path) else { return false }
        return String(decoding: data, as: UTF8.self) == identity
    }

    /// Les modeles ont-ils deja ete telecharges (meme pour une ancienne version) ?
    var hasDownloadedModels: Bool {
        FileManager.default.fileExists(atPath: Self.marker.path)
    }

    /// Telecharge (~1,6 Go la premiere fois) et prepare les modeles. Appels concurrents partages.
    @MainActor
    func prepare() async throws {
        if isPrepared { return }
        if let preparation {
            return try await preparation.value
        }
        isPreparing = true
        error = nil
        let task = Task { @MainActor in
            defer {
                self.isPreparing = false
                self.preparation = nil
            }
            do {
                try await self.engine.prepare(prewarm: true) { message in
                    Task { @MainActor in self.statusMessage = message }
                }
                FileManager.default.createFile(atPath: Self.marker.path, contents: Data(Self.identity.utf8))
                self.isPrepared = true
                self.statusMessage = nil
            } catch {
                self.error = error.localizedDescription
                throw error
            }
        }
        preparation = task
        try await task.value
    }

    /// Apres une mise a jour : on reprepare en arriere-plan des le lancement
    @MainActor
    func prepareInBackgroundIfNeeded() {
        guard !isPrepared, hasDownloadedModels, preparation == nil else { return }
        Task { try? await prepare() }
    }
}

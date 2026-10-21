import Foundation
import Network
import VoxaEngine

/// Version App Store : modeles du moteur natif (WhisperKit + SpeakerKit), dans le
/// meme processus que l'app (pas de Python, pas d'executable externe).
///
/// La preparation (telechargement puis optimisation Core ML pour la puce) tourne en
/// arriere-plan : l'app reste utilisable, les transcriptions attendent dans la file.
/// Core ML recommence l'optimisation quand l'app change (mise a jour) : la preparation
/// est memorisee pour une version precise de l'app et du modele.
@MainActor
@Observable
final class NativeModels {
    static let shared = NativeModels()

    /// Modele compresse : telechargement 2,5 fois plus leger, qualite equivalente (banc)
    let engine = NativeEngine(modelsDirectory: AppPaths.modelsDirectory, whisperVariant: NativeEngine.compactWhisperModel)

    /// Etape en cours (nil hors preparation)
    var progress: PreparationProgress?
    var isPreparing = false
    /// Message d'erreur pour l'utilisateur (nil si pas d'erreur)
    var error: String?
    /// Erreur reseau : on retente automatiquement au retour de la connexion
    var isNetworkError = false
    var isPrepared = NativeModels.markerIsCurrent
    /// Debut de l'etape en cours (temps ecoule affiche pendant l'optimisation)
    var phaseStartedAt: Date?

    /// Appele quand les modeles sont prets (la file de transcription reprend)
    var onReady: (@MainActor () -> Void)?

    private var preparation: Task<Void, Error>?
    private var pathMonitor: NWPathMonitor?

    private static var marker: URL {
        AppPaths.modelsDirectory.appendingPathComponent(".prepared")
    }

    /// Identite de l'app : version + date de l'executable (change a chaque mise a jour)
    /// + variante du modele (un changement de modele refait la preparation)
    private static var identity: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?")-\(info?["CFBundleVersion"] ?? "?")"
        let executable = Bundle.main.executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        return "\(version)-\(Int(executable?.timeIntervalSince1970 ?? 0))-\(NativeEngine.compactWhisperModel)"
    }

    private static var markerIsCurrent: Bool {
        guard let data = FileManager.default.contents(atPath: marker.path) else { return false }
        return String(decoding: data, as: UTF8.self) == identity
    }

    /// Le modele de transcription est-il deja sur le disque ? (plus de telechargement)
    var hasDownloadedModels: Bool {
        engine.isWhisperModelDownloaded
    }

    /// Telecharge (la premiere fois) et prepare les modeles. Appels concurrents partages.
    func prepare() async throws {
        if isPrepared { return }
        if let preparation {
            return try await preparation.value
        }
        isPreparing = true
        error = nil
        isNetworkError = false
        stopWaitingForNetwork()
        let task = Task { @MainActor in
            defer {
                self.isPreparing = false
                self.preparation = nil
                self.progress = nil
                self.phaseStartedAt = nil
            }
            let start = Date()
            do {
                try await self.engine.prepare(
                    prewarm: true,
                    progress: { progress in
                        Task { @MainActor in self.update(progress) }
                    },
                    log: { print("[NativeModels] \($0)") }
                )
                FileManager.default.createFile(atPath: Self.marker.path, contents: Data(Self.identity.utf8))
                // Changement de modele : l'ancien dossier ne sert plus
                for removed in self.engine.removeOtherWhisperVariants() {
                    print("[NativeModels] Ancien modele supprime: \(removed.lastPathComponent)")
                }
                print("[NativeModels] Modeles prets en \(Int(Date().timeIntervalSince(start))) s")
                self.isPrepared = true
                self.onReady?()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[NativeModels] ERREUR preparation: \(error)")
                let network = NativeEngine.isNetworkError(error)
                self.isNetworkError = network
                self.error = Self.userMessage(for: error, network: network)
                if network { self.retryWhenOnline() }
                throw error
            }
        }
        preparation = task
        try await task.value
    }

    /// Lancement de l'app : prepare en arriere-plan si besoin (premier lancement,
    /// mise a jour, changement de modele). Rien ne bloque l'interface.
    func prepareInBackgroundIfNeeded() {
        guard !isPrepared, preparation == nil else { return }
        Task { try? await prepare() }
    }

    /// Bouton Reessayer (le telechargement reprend la ou il s'etait arrete)
    func retry() {
        guard preparation == nil else { return }
        Task { try? await prepare() }
    }

    private func update(_ newProgress: PreparationProgress) {
        guard isPreparing else { return }
        if newProgress.phase != progress?.phase {
            phaseStartedAt = Date()
        }
        progress = newProgress
    }

    // MARK: - Erreurs

    nonisolated static func userMessage(for error: Error, network: Bool) -> String {
        if network {
            return String(localized: "The download was interrupted. Check your internet connection: Voxa will resume automatically when you are back online, or click Retry.")
        }
        return String(localized: "The transcription models could not be prepared (\(error.localizedDescription)). Click Retry to try again.")
    }

    /// Reprise automatique quand la connexion revient
    private func retryWhenOnline() {
        stopWaitingForNetwork()
        let monitor = NWPathMonitor()
        // Seulement au retour de la connexion (pas de boucle si le reseau semble ok
        // mais que le serveur ne repond pas : bouton Reessayer)
        final class Flag: @unchecked Sendable { var wasOffline = false }
        let flag = Flag()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else {
                flag.wasOffline = true
                return
            }
            guard flag.wasOffline else { return }
            Task { @MainActor in
                guard let self, self.isNetworkError, self.preparation == nil else { return }
                self.stopWaitingForNetwork()
                // Laisser la connexion s'etablir
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.retry()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func stopWaitingForNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}

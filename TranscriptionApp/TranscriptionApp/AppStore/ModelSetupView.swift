import SwiftUI
import VoxaEngine

/// Version App Store : preparation des modeles au premier lancement, sans bloquer
/// l'app. Un bandeau en haut de la fenetre (et une carte sur l'ecran d'accueil)
/// suit l'avancement : telechargement en octets, puis optimisation pour la puce. On
/// peut importer ou enregistrer pendant ce temps, les transcriptions attendent dans la file.
struct ModelPreparationBanner: View {
    var models = NativeModels.shared

    var body: some View {
        if !models.isPrepared {
            ModelPreparationStatus(models: models)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(models.error == nil ? Color.accentColor.opacity(0.08) : Color.orange.opacity(0.12))
        }
    }
}

/// Avancement de la preparation des modeles (ou erreur + Reessayer)
struct ModelPreparationStatus: View {
    var models = NativeModels.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = models.error {
                errorContent(error)
            } else {
                progressContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var progressContent: some View {
        let progress = models.progress
        HStack(spacing: 10) {
            Image(systemName: Self.icon(for: progress?.phase))
                .foregroundStyle(Color.accentColor)
            Text(Self.title(for: progress?.phase))
                .font(.callout.bold())
            if let step = Self.step(for: progress?.phase) {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            detailText(progress)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        // Pas de .fixedSize(vertical) sur les textes de cette vue : dans le
        // NavigationSplitView, la hauteur minimale calculee pour une largeur etroite
        // etirait toute la fenetre (liste et bandeaux hors de l'ecran)
        if let fraction = progress?.downloadFraction, progress?.phase == .downloading {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        } else if progress?.phase == .optimizing, let start = models.phaseStartedAt {
            // Duree estimee (elle varie selon le Mac) : la barre avance avec le temps
            // et s'arrete avant la fin, sans promettre de pourcentage exact
            TimelineView(.periodic(from: start, by: 1)) { context in
                ProgressView(value: Self.estimatedOptimizationFraction(context.date.timeIntervalSince(start)))
                    .progressViewStyle(.linear)
            }
        } else {
            ProgressView(value: 0)
                .progressViewStyle(.linear)
        }
        Text(Self.hint(for: progress?.phase))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func detailText(_ progress: PreparationProgress?) -> some View {
        if let progress, progress.phase == .downloading, progress.bytesTotal > 0 {
            Text("\(Self.bytes(progress.bytesDownloaded)) of \(Self.bytes(progress.bytesTotal)) (\(Int((progress.downloadFraction ?? 0) * 100))%)")
        } else if progress?.phase == .optimizing, let start = models.phaseStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text("\(Self.elapsed(context.date.timeIntervalSince(start))) elapsed")
            }
        }
    }

    private func errorContent(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcription models not ready")
                    .font(.callout.bold())
                Text(message)
                    .font(.caption)
                    }
            Spacer()
            Button("Retry") { models.retry() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Textes

    static func icon(for phase: PreparationProgress.Phase?) -> String {
        switch phase {
        case .downloading, .downloadingSpeakerModels: "arrow.down.circle"
        case .optimizing, .loading: "cpu"
        case nil: "hourglass"
        }
    }

    static func title(for phase: PreparationProgress.Phase?) -> String {
        switch phase {
        case .downloading: String(localized: "Downloading the transcription models")
        case .downloadingSpeakerModels: String(localized: "Downloading the speaker identification models")
        case .optimizing: String(localized: "Optimizing the models for this Mac")
        case .loading: String(localized: "Loading the models")
        case nil: String(localized: "Preparing the transcription models")
        }
    }

    static func step(for phase: PreparationProgress.Phase?) -> String? {
        switch phase {
        case .downloading, .downloadingSpeakerModels: String(localized: "Step 1 of 2")
        case .optimizing, .loading: String(localized: "Step 2 of 2")
        case nil: nil
        }
    }

    static func hint(for phase: PreparationProgress.Phase?) -> String {
        switch phase {
        case .optimizing:
            String(localized: "One-time step, done offline. It usually takes a few minutes. You can already import files or record a meeting: transcription starts automatically when the models are ready.")
        default:
            String(localized: "One-time setup. You can already import files or record a meeting: transcription starts automatically when the models are ready.")
        }
    }

    /// Optimisation : ~3 min sur un M3 (mesure). Avance vite puis ralentit, plafonne a 95 %.
    static func estimatedOptimizationFraction(_ elapsed: TimeInterval) -> Double {
        min(0.95, 1 - exp(-max(0, elapsed) / 120))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Ecran d'accueil (zone de detail vide) tant que les modeles ne sont pas prets
struct ModelWelcomeView: View {
    var models = NativeModels.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            VStack(spacing: 8) {
                Text("Welcome to Voxa")
                    .font(.largeTitle.bold())
                Text("Transcribe your meetings on your Mac, with speaker identification. Everything stays on this computer.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 12) {
                stepRow(
                    String(localized: "Download the transcription models (once)"),
                    icon: "arrow.down.circle",
                    state: downloadState
                )
                stepRow(
                    String(localized: "Optimize them for this Mac (once, a few minutes)"),
                    icon: "cpu",
                    state: optimizeState
                )
                Label("No account, no internet needed afterwards", systemImage: "lock.shield")
            }
            .frame(maxWidth: 420, alignment: .leading)

            ModelPreparationStatus(models: models)
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 520)

            Text("You don't have to wait: import an audio file or record a meeting now. Voxa transcribes it as soon as the models are ready.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum StepState { case waiting, running, done }

    private var downloadState: StepState {
        switch models.progress?.phase {
        case .downloading, .downloadingSpeakerModels: .running
        case .optimizing, .loading: .done
        case nil: models.hasDownloadedModels ? .done : (models.isPreparing ? .running : .waiting)
        }
    }

    private var optimizeState: StepState {
        switch models.progress?.phase {
        case .optimizing, .loading: .running
        default: .waiting
        }
    }

    @ViewBuilder
    private func stepRow(_ title: String, icon: String, state: StepState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .running:
                Image(systemName: "arrow.forward.circle.fill").foregroundStyle(Color.accentColor)
            case .waiting:
                Image(systemName: icon)
            }
            Text(title)
        }
    }
}

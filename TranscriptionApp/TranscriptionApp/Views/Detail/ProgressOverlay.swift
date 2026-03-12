import SwiftUI

struct ProgressOverlay: View {
    let project: TranscriptionProject
    var summaryError: String?
    var ollamaService: OllamaService?
    var estimationService: EstimationService?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: statusIcon)
                .font(.system(size: 50))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, isActive: project.status.isProcessing)

            if project.status == .generatingSummary {
                Text(project.status.label)
                    .font(.title2.bold())
            } else {
                Text(String(localized: "Processing..."))
                    .font(.title2.bold())
            }

            if project.status == .generatingSummary {
                if let ollama = ollamaService, ollama.isPulling {
                    // Telechargement du modele en cours
                    VStack(spacing: 12) {
                        ProgressView(value: ollama.pullProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 300)

                        Text("Downloading model \(ollama.pullModelName ?? "")... \(Int(ollama.pullProgress * 100))%")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Progression indeterminee pour la synthese
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)

                    Text("Analyzing contributions with Ollama...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if project.status.isProcessing {
                ProgressView(value: project.progressPercent, total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 300)

                HStack(spacing: 12) {
                    Text("\(Int(project.progressPercent))%")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if let estimation = estimationService?.formattedRemaining {
                        Text(estimation)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(project.status.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if project.status == .pending {
                Text("Waiting to process...")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusIcon: String {
        switch project.status {
        case .generatingSummary:
            "brain"
        default:
            "waveform"
        }
    }
}

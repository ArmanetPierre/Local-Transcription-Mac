import SwiftUI

/// Version App Store : premier lancement. Telecharge et prepare les modeles de
/// transcription (rien a installer d'autre).
struct ModelSetupView: View {
    let models: NativeModels

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 8) {
                Text("Welcome to Voxa")
                    .font(.largeTitle.bold())
                Text("Transcribe your meetings on your Mac, with speaker identification. Everything stays on this computer.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Download the transcription models (about 1.6 GB, once)", systemImage: "arrow.down.circle")
                Label("Optimize them for this Mac (a few minutes)", systemImage: "cpu")
                Label("No account, no internet needed afterwards", systemImage: "lock.shield")
            }
            .frame(maxWidth: 420, alignment: .leading)

            if models.isPreparing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(models.statusMessage ?? String(localized: "Preparing..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("You can leave this window open, it takes a few minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { try? await models.prepare() }
                } label: {
                    Text("Download and prepare")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let error = models.error {
                Text("Download failed: \(error). Check your internet connection and try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 520)
    }
}

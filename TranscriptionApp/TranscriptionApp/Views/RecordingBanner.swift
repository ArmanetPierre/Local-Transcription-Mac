import SwiftUI

/// Bandeau affiche en haut de la fenetre principale pendant un enregistrement
/// (chrono + bouton d'arret) ou quand une permission manque : l'icone de la barre
/// des menus peut etre cachee par l'encoche, la fenetre doit suffire.
struct RecordingBanner: View {
    let recordingVM: RecordingVM
    let listVM: TranscriptionListVM

    var body: some View {
        if recordingVM.recordingService.isRecording {
            recordingBar
        } else if recordingVM.showPermissionAlert {
            permissionBar
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording in progress")
                .font(.callout.bold())
            Text(recordingVM.formattedElapsedTime)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                recordingVM.stopAndTranscribe(listVM: listVM)
            } label: {
                Label("Stop and transcribe", systemImage: "stop.circle.fill")
            }
            .tint(.red)
            .help("⇧⌘R")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.12))
    }

    private var permissionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(recordingVM.permissionAlertMessage)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
                )
                recordingVM.showPermissionAlert = false
            }
            Button {
                recordingVM.showPermissionAlert = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

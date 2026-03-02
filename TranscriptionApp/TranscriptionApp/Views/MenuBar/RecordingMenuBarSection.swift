import SwiftUI

struct RecordingMenuBarSection: View {
    let recordingVM: RecordingVM
    let listVM: TranscriptionListVM

    var body: some View {
        if recordingVM.recordingService.isRecording {
            // Active recording display
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Enregistrement en cours")
                        .font(.callout.bold())
                }

                Text(recordingVM.formattedElapsedTime)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Button {
                recordingVM.stopAndTranscribe(listVM: listVM)
            } label: {
                Label("Arreter et transcrire", systemImage: "stop.circle.fill")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        } else {
            // Idle — show record button
            Button {
                recordingVM.startRecording()
            } label: {
                Label("Enregistrer une reunion", systemImage: "record.circle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Show error if any
            if let error = recordingVM.recordingService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }

        // Permission alert (shown inline since .menu style doesn't support .alert)
        if recordingVM.showPermissionAlert {
            VStack(alignment: .leading, spacing: 4) {
                Text(recordingVM.permissionAlertMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Ouvrir Reglages Systeme") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
                    )
                    recordingVM.showPermissionAlert = false
                }
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

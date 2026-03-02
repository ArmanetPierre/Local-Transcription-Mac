import SwiftUI

struct MenuBarView: View {
    let listVM: TranscriptionListVM
    let recordingVM: RecordingVM

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section enregistrement
            RecordingMenuBarSection(recordingVM: recordingVM, listVM: listVM)

            Divider()

            // Section transcription
            if listVM.isProcessing, let project = listVM.currentProject {
                // Section: En cours
                processingSection(project: project)
            } else {
                // Idle
                Label("Aucune transcription en cours", systemImage: "checkmark.circle")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if !listVM.batchQueue.isEmpty {
                Divider()
                Label(
                    "\(listVM.batchQueue.count) fichier\(listVM.batchQueue.count > 1 ? "s" : "") en attente",
                    systemImage: "tray.full"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            // Actions
            if listVM.isProcessing {
                Button {
                    listVM.cancelCurrent()
                } label: {
                    Label("Annuler", systemImage: "xmark.circle")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                // Amener la fenetre au premier plan
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("Ouvrir Voxa", systemImage: "macwindow")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            Button("Quitter") {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(width: 280)
    }

    // MARK: - Processing Section

    @ViewBuilder
    private func processingSection(project: TranscriptionProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Titre du fichier
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
                Text(project.title)
                    .font(.callout.bold())
                    .lineLimit(1)
            }

            // Etape en cours
            Text(project.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Barre de progression
            if project.status != .generatingSummary {
                ProgressView(value: project.progressPercent, total: 100)
                    .progressViewStyle(.linear)

                HStack {
                    Text("\(Int(project.progressPercent))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let remaining = listVM.estimationService.formattedRemaining {
                        Text(remaining)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

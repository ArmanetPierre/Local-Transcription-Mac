import SwiftUI

struct SegmentRow: View {
    @Bindable var segment: Segment
    let speakerDisplayName: String
    let isPlaying: Bool
    let onSeek: () -> Void
    let onRenameSpeaker: (String) -> Void

    @State private var showRenamePopover = false
    @State private var renameText = ""
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timestamp
            VStack(alignment: .trailing) {
                Text(TimeFormatting.shortTimestamp(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50, alignment: .trailing)
            .onTapGesture { onSeek() }

            // Speaker badge
            SpeakerBadge(
                name: speakerDisplayName,
                label: segment.speakerLabel ?? "Unknown",
                onTap: {
                    renameText = speakerDisplayName == (segment.speakerLabel ?? "") ? "" : speakerDisplayName
                    showRenamePopover = true
                }
            )
            .popover(isPresented: $showRenamePopover) {
                VStack(spacing: 8) {
                    Text("Rename \(segment.speakerLabel ?? "")")
                        .font(.headline)
                    TextField("Speaker name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit {
                            onRenameSpeaker(renameText)
                            showRenamePopover = false
                        }

                    // Suggestions depuis l'historique
                    let suggestions = SpeakerNameHistory.suggestions(for: renameText)
                    if !suggestions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(suggestions.prefix(4), id: \.self) { name in
                                Button(name) {
                                    renameText = name
                                    onRenameSpeaker(name)
                                    showRenamePopover = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    HStack {
                        Button("Cancel") { showRenamePopover = false }
                        Button("OK") {
                            onRenameSpeaker(renameText)
                            showRenamePopover = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }

            // Text content
            TextField("", text: $segment.text, axis: .vertical)
                .textFieldStyle(.plain)
                .onSubmit { segment.modelContext?.saveLogged("correction texte") }
                .onChange(of: segment.text) { scheduleSave() }
                .font(isPlaying ? .body.bold() : .body)
                .lineLimit(1...50)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onSeek() }
    }

    /// Sauvegarde 2 s apres la derniere frappe (une correction ne doit pas se perdre)
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            segment.modelContext?.saveLogged("correction texte")
        }
    }
}

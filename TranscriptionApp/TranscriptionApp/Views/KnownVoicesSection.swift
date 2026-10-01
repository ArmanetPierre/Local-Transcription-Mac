import SwiftUI

/// Section des Reglages : personnes dont Voxa connait la voix.
/// Permet de renommer (ou fusionner, si le nom existe deja) et d'oublier une voix.
struct KnownVoicesSection: View {
    @State private var speakers: [(name: String, samples: Int)] = []
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        Section("Known Voices") {
            if speakers.isEmpty {
                Text("No voices yet. Name the speakers of a transcription and Voxa will recognize them next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(speakers, id: \.name) { speaker in
                    HStack {
                        Text(speaker.name)
                        Spacer()
                        Text("\(speaker.samples) samples")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("One sample per transcription where this person was named. More samples recognize them better across recording setups.")
                        Button {
                            newName = speaker.name
                            renaming = speaker.name
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename or merge with another person")
                        Button(role: .destructive) {
                            deleting = speaker.name
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this voice")
                    }
                }
                Text("Renaming to an existing name merges the two people.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reload)
        .alert("Rename \(renaming ?? "")", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming {
                    SpeakerEmbeddingStore.shared.renameSpeaker(old, to: newName)
                    SpeakerNameHistory.addNames([newName])
                }
                renaming = nil
                reload()
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Forget the voice of \(deleting ?? "")?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Forget", role: .destructive) {
                if let name = deleting {
                    SpeakerEmbeddingStore.shared.deleteSpeaker(name)
                }
                deleting = nil
                reload()
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Voxa will no longer recognize this person automatically. Existing transcriptions keep their names.")
        }
    }

    private func reload() {
        speakers = SpeakerEmbeddingStore.shared.knownSpeakers()
    }
}

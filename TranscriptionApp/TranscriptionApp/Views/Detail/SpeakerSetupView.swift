import SwiftUI

struct SpeakerSetupView: View {
    @Bindable var project: TranscriptionProject
    var viewModel: TranscriptionDetailVM
    @State private var editedNames: [String: String] = [:]
    @State private var focusedSpeaker: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "person.2.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)

                    Text("Identify Speakers")
                        .font(.title2.bold())

                    Text("Listen to samples and name each speaker")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Speaker cards
                ForEach(project.uniqueSpeakers, id: \.self) { speakerLabel in
                    speakerCard(for: speakerLabel)
                }

                // Actions
                HStack {
                    Button("Skip") {
                        SpeakerEmbeddingStore.shared.clearPending(projectId: project.id)
                        viewModel.skipSpeakerNames(project: project)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Confirm and continue") {
                        // Enregistrer les noms saisis
                        for (label, name) in editedNames {
                            viewModel.renameSpeaker(in: project, label: label, newName: name)
                        }
                        // Sauvegarder les noms dans l'historique global (suggestions texte)
                        SpeakerNameHistory.addNames(Array(editedNames.values))

                        // Sauvegarder les embeddings vocaux avec les noms confirmes
                        SpeakerEmbeddingStore.shared.confirmSpeakerNames(
                            projectId: project.id,
                            labelToName: editedNames
                        )

                        viewModel.confirmSpeakerNames(project: project)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
            .padding(30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            print("[SpeakerSetup] onAppear: \(project.uniqueSpeakers.count) speakers, segments=\(project.segments.count)")
            // Initialiser les noms edites avec les noms existants
            // (inclut les noms pre-remplis par le matching d'embeddings vocaux)
            for speaker in project.uniqueSpeakers {
                editedNames[speaker] = project.speakerNames[speaker] ?? ""
            }
            // Charger l'audio pour pouvoir ecouter les extraits
            viewModel.loadAudio(for: project)
        }
    }

    // MARK: - Speaker Card

    private func speakerCard(for speakerLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header du speaker
            HStack {
                Circle()
                    .fill(SpeakerColors.color(for: speakerLabel))
                    .frame(width: 12, height: 12)

                Text(speakerLabel)
                    .font(.headline)

                let segmentCount = project.sortedSegments.filter { $0.speakerLabel == speakerLabel }.count
                Text("\(segmentCount) contributions")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Bouton Play pour ecouter un extrait
                Button {
                    playSample(for: speakerLabel)
                } label: {
                    Label(
                        viewModel.audioService.isLoaded ? "Listen" : "Audio unavailable",
                        systemImage: viewModel.audioService.isLoaded ? "play.circle.fill" : "speaker.slash"
                    )
                    .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.audioService.isLoaded)
            }

            // Extraits texte
            let samples = project.sampleSegments(for: speakerLabel, count: 3)
            ForEach(samples, id: \.id) { segment in
                HStack(alignment: .top, spacing: 8) {
                    Text(TimeFormatting.shortTimestamp(segment.startTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)

                    Text("\"\(segment.text.prefix(100))\(segment.text.count > 100 ? "..." : "")\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Champ nom avec suggestions
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Name:")
                        .font(.callout)
                    TextField("Enter name...", text: nameBinding(for: speakerLabel), onEditingChanged: { editing in
                        focusedSpeaker = editing ? speakerLabel : nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
                }

                // Suggestions basees sur l'historique
                let query = editedNames[speakerLabel] ?? ""
                let suggestions = SpeakerNameHistory.suggestions(for: query)
                    .filter { name in
                        // Exclure les noms deja attribues a d'autres speakers
                        !editedNames.contains { $0.key != speakerLabel && $0.value == name }
                    }
                if focusedSpeaker == speakerLabel && !suggestions.isEmpty && query != suggestions.first {
                    HStack(spacing: 6) {
                        ForEach(suggestions.prefix(5), id: \.self) { name in
                            Button(name) {
                                editedNames[speakerLabel] = name
                                focusedSpeaker = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.leading, 48)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func nameBinding(for label: String) -> Binding<String> {
        Binding(
            get: { editedNames[label] ?? "" },
            set: { editedNames[label] = $0 }
        )
    }

    private func playSample(for speakerLabel: String) {
        let samples = project.sampleSegments(for: speakerLabel, count: 3)
        print("[SpeakerSetup] playSample(\(speakerLabel)): \(samples.count) samples, audioLoaded=\(viewModel.audioService.isLoaded)")
        guard let first = samples.first else {
            print("[SpeakerSetup] Aucun sample trouve pour \(speakerLabel)")
            return
        }
        print("[SpeakerSetup] Seek vers segment \(first.index) a \(first.startTime)s")
        viewModel.seekToSegment(first)
    }
}

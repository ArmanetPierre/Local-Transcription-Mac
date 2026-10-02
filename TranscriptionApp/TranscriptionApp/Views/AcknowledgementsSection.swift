import SwiftUI

/// Licences des composants et modeles utilises (CC BY 4.0 impose la mention des auteurs).
struct AcknowledgementsSection: View {
    private struct Credit: Identifiable {
        let name: String
        let detail: String
        let url: String
        var id: String { name }
    }

    private let credits: [Credit] = {
        var list = [
            Credit(name: "Whisper", detail: "OpenAI — MIT License", url: "https://github.com/openai/whisper"),
            Credit(name: "WhisperKit & SpeakerKit", detail: "Argmax, Inc. — MIT License",
                   url: "https://github.com/argmaxinc/WhisperKit"),
            Credit(name: "SpeakerKit Core ML models", detail: "Argmax, Inc. — CC BY 4.0",
                   url: "https://huggingface.co/argmaxinc/speakerkit-coreml"),
            Credit(name: "pyannote speaker-diarization-community-1", detail: "pyannoteAI — CC BY 4.0",
                   url: "https://huggingface.co/pyannote/speaker-diarization-community-1"),
        ]
        #if !APPSTORE
        list.append(Credit(name: "MLX Whisper", detail: "Apple — MIT License", url: "https://github.com/ml-explore/mlx-examples"))
        list.append(Credit(name: "pyannote.audio", detail: "CNRS — MIT License", url: "https://github.com/pyannote/pyannote-audio"))
        list.append(Credit(name: "Sparkle", detail: "Sparkle Project — MIT License", url: "https://sparkle-project.org"))
        #endif
        return list
    }()

    var body: some View {
        Section("Acknowledgements") {
            ForEach(credits) { credit in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credit.name)
                        Text(credit.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = URL(string: credit.url) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
        }
    }
}

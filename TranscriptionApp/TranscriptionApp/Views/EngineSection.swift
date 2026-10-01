import SwiftUI

/// Section des Reglages : choix du moteur de transcription (Python ou natif).
struct EngineSection: View {
    @AppStorage(TranscriptionEngine.defaultsKey) private var engine = TranscriptionEngine.python.rawValue
    @State private var native = NativeEngineSupport.shared
    @State private var isPrepared = NativeEngineSupport.isPrepared

    var body: some View {
        Section("Transcription Engine") {
            Picker("Engine", selection: $engine) {
                ForEach(TranscriptionEngine.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }

            if engine == TranscriptionEngine.native.rawValue {
                Text("Native engine: about 2.5× faster, no Python needed. Quality is close to the Python engine but it may miss a few words when people talk over each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if isPrepared {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Models ready")
                    } else if native.isPreparing {
                        ProgressView().controlSize(.small)
                        Text(native.lastMessage ?? String(localized: "Preparing..."))
                            .lineLimit(1)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Models not prepared for this version: the Python engine is used meanwhile")
                    }
                    Spacer()
                    if !isPrepared {
                        Button("Prepare") {
                            Task {
                                await native.prepare()
                                isPrepared = NativeEngineSupport.isPrepared
                            }
                        }
                        .disabled(native.isPreparing)
                        .controlSize(.small)
                    }
                }
                .font(.caption)

                if !isPrepared {
                    Text("Downloads about 1.6 GB and optimizes the models for this Mac. Takes a few minutes, once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = native.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

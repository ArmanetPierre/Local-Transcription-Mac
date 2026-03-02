import SwiftData
import SwiftUI

@main
struct TranscriptionApp: App {
    let modelContainer: ModelContainer
    @State private var listVM = TranscriptionListVM()
    @State private var recordingVM = RecordingVM()

    init() {
        // Creer le ModelContainer explicitement pour le partager
        // entre WindowGroup et MenuBarExtra (qui ne supporte pas @Environment)
        self.modelContainer = try! ModelContainer(for: TranscriptionProject.self)

        // Arreter le serveur Ollama et l'enregistrement a la fermeture
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            OllamaService.stopServer()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(listVM: listVM)
                .onAppear {
                    recordingVM.modelContainer = modelContainer
                }
        }
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarView(listVM: listVM, recordingVM: recordingVM)
        } label: {
            HStack(spacing: 4) {
                if recordingVM.recordingService.isRecording {
                    // Etat: enregistrement en cours
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text(recordingVM.formattedElapsedTime)
                        .font(.caption.monospacedDigit())
                } else if listVM.isProcessing {
                    // Etat: transcription en cours
                    Image(systemName: "waveform.circle.fill")
                    if let remaining = listVM.estimationService.shortFormattedRemaining {
                        Text(remaining)
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("\(Int(listVM.currentProject?.progressPercent ?? 0))%")
                            .font(.caption.monospacedDigit())
                    }
                } else {
                    // Etat: idle
                    Image(systemName: "waveform.circle")
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

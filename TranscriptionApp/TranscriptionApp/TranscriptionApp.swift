import Sparkle
import SwiftData
import SwiftUI

@main
struct TranscriptionApp: App {
    let modelContainer: ModelContainer
    @State private var listVM = TranscriptionListVM()
    @State private var recordingVM = RecordingVM()
    @State private var dependencyManager = DependencyManager()
    @AppStorage("setup_completed") private var setupCompleted = false

    let updaterController: SPUStandardUpdaterController

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Stocker la base SwiftData dans le dossier Voxa (Application Support)
        // plutot que le defaut ~/Library/Application Support/default.store
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let storeURL = appSupport
            .appendingPathComponent("Voxa", isDirectory: true)
            .appendingPathComponent("Voxa.store")
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = ModelConfiguration(url: storeURL)
        self.modelContainer = try! ModelContainer(
            for: TranscriptionProject.self,
            configurations: config
        )

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
            Group {
                if setupCompleted {
                    ContentView(listVM: listVM)
                        .onAppear {
                            recordingVM.modelContainer = modelContainer
                        }
                        .task {
                            // Silent re-check: if venv was deleted, go back to setup
                            await dependencyManager.checkAll()
                            if !dependencyManager.overallReady {
                                setupCompleted = false
                            }
                        }
                } else {
                    SetupView(manager: dependencyManager) {
                        setupCompleted = true
                    }
                }
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

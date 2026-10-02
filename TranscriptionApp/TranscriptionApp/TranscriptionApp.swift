#if !APPSTORE
import Sparkle
#endif
import SwiftData
import SwiftUI

@main
struct TranscriptionApp: App {
    let modelContainer: ModelContainer
    @State private var listVM: TranscriptionListVM
    @State private var recordingVM = RecordingVM()
    #if APPSTORE
    // Version App Store : moteur natif uniquement, mises a jour par l'App Store
    @State private var nativeModels = NativeModels.shared
    #else
    @State private var dependencyManager = DependencyManager()
    @AppStorage("setup_completed") private var setupCompleted = false

    let updaterController: SPUStandardUpdaterController
    #endif

    /// Vrai quand l'app sert d'hote aux tests unitaires
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// API locale pour le serveur MCP (Claude Code)
    let apiServer: LocalAPIServer

    init() {
        #if !APPSTORE
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: !Self.isRunningTests,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif

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
        // Base en memoire pendant les tests unitaires : ne jamais toucher la vraie
        let config = Self.isRunningTests
            ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: storeURL)
        self.modelContainer = try! ModelContainer(
            for: TranscriptionProject.self,
            configurations: config
        )

        #if !APPSTORE
        if !Self.isRunningTests {
            HuggingFaceToken.migrateFromUserDefaults()
        }
        #endif

        let listVM = TranscriptionListVM()
        self._listVM = State(initialValue: listVM)
        self.apiServer = LocalAPIServer(listVM: listVM, modelContainer: modelContainer)
        // Pas d'API pendant les tests unitaires (l'app sert d'hote aux tests)
        if !Self.isRunningTests {
            apiServer.start()
            #if APPSTORE
            ScriptDeployment.deployMCPScript()
            #endif
        }

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
                #if APPSTORE
                if nativeModels.isPrepared || nativeModels.hasDownloadedModels {
                    ContentView(listVM: listVM)
                        .onAppear {
                            recordingVM.modelContainer = modelContainer
                        }
                        .task {
                            guard !Self.isRunningTests else { return }
                            listVM.resumeInterrupted(modelContext: modelContainer.mainContext)
                            // Apres une mise a jour, Core ML reprepare les modeles
                            nativeModels.prepareInBackgroundIfNeeded()
                        }
                } else {
                    ModelSetupView(models: nativeModels)
                }
                #else
                if setupCompleted {
                    ContentView(listVM: listVM)
                        .onAppear {
                            recordingVM.modelContainer = modelContainer
                        }
                        .task {
                            guard !Self.isRunningTests else { return }
                            // Silent re-check: if venv was deleted, go back to setup
                            await dependencyManager.checkAll()
                            if !dependencyManager.overallReady {
                                setupCompleted = false
                            } else {
                                listVM.resumeInterrupted(modelContext: modelContainer.mainContext)
                                NativeEngineSupport.shared.prepareIfNeeded()
                            }
                        }
                } else {
                    SetupView(manager: dependencyManager) {
                        setupCompleted = true
                    }
                }
                #endif
            }
        }
        .modelContainer(modelContainer)

        Settings {
            #if APPSTORE
            SettingsView()
            #else
            SettingsView(updater: updaterController.updater)
            #endif
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

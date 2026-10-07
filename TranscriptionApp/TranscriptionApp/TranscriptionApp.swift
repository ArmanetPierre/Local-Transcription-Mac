#if !APPSTORE
import Sparkle
#endif
import SwiftData
import SwiftUI

@main
struct TranscriptionApp: App {
    let modelContainer: ModelContainer
    @State private var listVM: TranscriptionListVM
    @State private var recordingVM: RecordingVM
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        if !Self.isRunningTests {
            AppLog.setUp()
        }
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
        self.modelContainer = Self.openStore(config: config, storeURL: storeURL)

        #if !APPSTORE
        if !Self.isRunningTests {
            HuggingFaceToken.migrateFromUserDefaults()
        }
        #endif

        let listVM = TranscriptionListVM()
        self._listVM = State(initialValue: listVM)
        let recordingVM = RecordingVM()
        recordingVM.modelContainer = modelContainer
        recordingVM.configure(listVM: listVM)
        self._recordingVM = State(initialValue: recordingVM)
        self.apiServer = LocalAPIServer(listVM: listVM, modelContainer: modelContainer)
        // Pas d'API pendant les tests unitaires (l'app sert d'hote aux tests)
        if !Self.isRunningTests {
            apiServer.start()
            #if APPSTORE
            ScriptDeployment.deployMCPScript()
            #endif
        }

        // Filet de securite : l'autosave de SwiftData ne se declenche pas toujours
        // (modifications faites ailleurs que via les sauvegardes explicites)
        let mainContext = modelContainer.mainContext
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { mainContext.saveLogged("app en arriere-plan") }
        }

        // Quitter : finaliser un enregistrement en cours, arreter le moteur, sauvegarder
        AppDelegate.prepareForTermination = {
            if recordingVM.recordingService.isRecording {
                print("[App] Fermeture pendant un enregistrement : finalisation")
                await recordingVM.stopAndImport(listVM: listVM, reason: "fermeture de l'app")
            }
            // Un arret lance juste avant (bouton Stop puis Cmd-Q) doit aussi aboutir
            await recordingVM.waitUntilIdle()
            listVM.stopForQuit()
            mainContext.saveLogged("fermeture")
            OllamaService.stopServer()
        }
    }

    /// Message a afficher au lancement si la base a du etre mise de cote
    @MainActor static var storeRecoveryMessage: String?

    /// Ouvre la base. Si elle est illisible (migration ratee apres une mise a jour,
    /// fichier abime), on la met de cote au lieu de planter a chaque lancement.
    private static func openStore(config: ModelConfiguration, storeURL: URL) -> ModelContainer {
        do {
            return try ModelContainer(for: TranscriptionProject.self, configurations: config)
        } catch {
            print("[App] ERREUR ouverture de la base: \(error)")
        }
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: storeURL.path + suffix)
            if fm.fileExists(atPath: file.path) {
                try? fm.moveItem(at: file, to: URL(fileURLWithPath: storeURL.path + ".unreadable-\(stamp)" + suffix))
            }
        }
        MainActor.assumeIsolated {
            storeRecoveryMessage = String(localized: "Your transcription database could not be opened and was set aside (Voxa.store.unreadable-\(stamp) in the Voxa folder). Your audio files are untouched.")
        }
        do {
            return try ModelContainer(for: TranscriptionProject.self, configurations: config)
        } catch {
            print("[App] ERREUR base neuve: \(error) — base en memoire")
            return try! ModelContainer(
                for: TranscriptionProject.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }

    /// Reprise des transcriptions et des enregistrements interrompus : une seule fois par
    /// lancement (le `.task` de la fenetre se relance si elle est fermee puis rouverte).
    @MainActor
    private func launchTasksOnce() async {
        guard !AppDelegate.didRunLaunchTasks else { return }
        AppDelegate.didRunLaunchTasks = true
        if let message = Self.storeRecoveryMessage {
            recordingVM.recordingService.errorMessage = message
        }
        listVM.resumeInterrupted(modelContext: modelContainer.mainContext)
        await recordingVM.recoverInterrupted(listVM: listVM)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if APPSTORE
                if nativeModels.isPrepared || nativeModels.hasDownloadedModels {
                    ContentView(listVM: listVM, recordingVM: recordingVM)
                                    .task {
                            guard !Self.isRunningTests else { return }
                            await launchTasksOnce()
                            // Apres une mise a jour, Core ML reprepare les modeles
                            nativeModels.prepareInBackgroundIfNeeded()
                        }
                } else {
                    ModelSetupView(models: nativeModels)
                }
                #else
                if setupCompleted {
                    ContentView(listVM: listVM, recordingVM: recordingVM)
                                    .task {
                            guard !Self.isRunningTests else { return }
                            // Silent re-check: if venv was deleted, go back to setup
                            await dependencyManager.checkAll()
                            if !dependencyManager.overallReady {
                                setupCompleted = false
                            } else {
                                await launchTasksOnce()
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
        .commands {
            CommandGroup(after: .help) {
                Button("Show Logs in Finder") { AppLog.reveal() }
            }
            CommandMenu("Recording") {
                if recordingVM.recordingService.isRecording {
                    Button("Stop and transcribe") {
                        recordingVM.stopAndTranscribe(listVM: listVM, reason: "menu Enregistrement / ⇧⌘R")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                } else {
                    Button("Record a meeting") {
                        recordingVM.startRecording()
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }

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
                    // Etat: enregistrement en cours. Icone seule, sans chrono : macOS ajoute
                    // son indicateur de capture au meme moment, et une icone qui s'elargit
                    // finit cachee sous l'encoche (plus moyen d'arreter). Le chrono est dans
                    // le menu et dans le bandeau de la fenetre.
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.multicolor)
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

/// Delegue AppKit : fermeture propre (enregistrement en cours finalise avant de quitter).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var prepareForTermination: (@MainActor () async -> Void)?
    @MainActor static var didRunLaunchTasks = false
    private var isTerminating = false

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = Self.prepareForTermination else { return .terminateNow }
        // Deuxieme demande pendant la finalisation : la premiere quittera une fois terminee
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        Task { @MainActor in
            await prepare()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

#if !APPSTORE
import Sparkle
#endif
import SwiftUI

struct SettingsView: View {
    #if !APPSTORE
    /// Updater de l'app (deja demarre). SwiftUI recree cette vue a chaque
    /// rafraichissement de l'app : rien de couteux ne doit etre fait dans init.
    let updater: SPUUpdater
    #else
    @State private var folderAccess = FolderAccess.shared
    #endif

    @State private var hfToken = ""
    @AppStorage("default_model") private var defaultModel = WhisperModel.largeV3Turbo.rawValue
    @AppStorage("python_path") private var pythonPath = PythonBridge.defaultPythonPath
    @AppStorage("script_path") private var scriptPath = PythonBridge.defaultScriptPath
    @AppStorage("default_diarization") private var defaultDiarization = true
    @AppStorage("ollama_model") private var ollamaModel = OllamaModel.llama3_1.rawValue
    @AppStorage("ollama_auto_download") private var ollamaAutoDownload = false
    @AppStorage("setup_completed") private var setupCompleted = true

    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var isReinstallingPackages = false
    @State private var reinstallLog = ""
    @State private var mcpCommandCopied = false

    private var claudeMCPCommand: String {
        #if APPSTORE
        let python = "python3"
        #else
        let python = FileManager.default.fileExists(atPath: pythonPath) ? pythonPath : "python3"
        #endif
        return "claude mcp add voxa --scope user -- \"\(python)\" \"\(LocalAPIServer.mcpScriptPath)\""
    }

    var body: some View {
        Form {
            #if !APPSTORE
            Section("HuggingFace") {
                SecureField("HuggingFace Token", text: $hfToken)
                    .onChange(of: hfToken) { _, newValue in HuggingFaceToken.value = newValue }
                    .help("Required for downloading pyannote models (diarization)")
                Text("Create a token at huggingface.co/settings/tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #endif

            Section("Transcription") {
                #if !APPSTORE
                Picker("Default model", selection: $defaultModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                #endif

                Toggle("Default diarization", isOn: $defaultDiarization)
                    .help("Automatically identify different speakers")
            }

            #if !APPSTORE
            EngineSection()
            #endif

            Section("LLM Summary (Ollama)") {
                Picker("Ollama Model", selection: $ollamaModel) {
                    ForEach(OllamaModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                .help("Model used to generate speaker summaries")

                Toggle("Download models automatically", isOn: $ollamaAutoDownload)
                    .help("Otherwise Voxa asks before downloading a missing model (several GB)")

                HStack(spacing: 8) {
                    switch ollamaStatus {
                    case .unknown:
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                        Text("Unknown status")
                            .foregroundStyle(.secondary)
                    case .checking:
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking...")
                            .foregroundStyle(.secondary)
                    case .available:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ollama available")
                    case .unavailable:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("Ollama unavailable")
                    }

                    Spacer()

                    Button("Check") {
                        checkOllama()
                    }
                    .controlSize(.small)
                }
                .font(.caption)

                Text("Run 'ollama serve' to enable automatic summaries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            KnownVoicesSection()

            Section("Claude Code (MCP)") {
                Text("Let Claude Code transcribe your meetings, read transcripts and write meeting reports in Voxa. Run this command once in a terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top) {
                    Text(claudeMCPCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(mcpCommandCopied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(claudeMCPCommand, forType: .string)
                        mcpCommandCopied = true
                    }
                    .controlSize(.small)
                }

                Text("Voxa must be running for Claude to use it (it is opened automatically if needed).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if APPSTORE
                // Sandbox : Claude ne peut faire transcrire que les dossiers autorises ici
                Text("Allowed folders: Claude Code can ask Voxa to transcribe files located in these folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(folderAccess.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            folderAccess.remove(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                Button("Add Folder...") {
                    folderAccess.addFolder()
                }
                .controlSize(.small)
                #endif
            }

            #if !APPSTORE
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))

                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
            }

            Section("Setup") {
                HStack {
                    if FileManager.default.fileExists(atPath: pythonPath) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Python found")
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text("Python not found")
                    }
                    Spacer()
                    Button("Re-run Setup") {
                        setupCompleted = false
                    }
                    .controlSize(.small)
                }
                .font(.caption)

                DisclosureGroup("Advanced") {
                    HStack {
                        TextField("Python", text: $pythonPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                pythonPath = url.path
                            }
                        }
                    }

                    HStack {
                        TextField("Script", text: $scriptPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowedContentTypes = [.pythonScript]
                            if panel.runModal() == .OK, let url = panel.url {
                                scriptPath = url.path
                            }
                        }
                    }

                    Button("Reset to defaults") {
                        pythonPath = PythonBridge.defaultPythonPath
                        scriptPath = PythonBridge.defaultScriptPath
                    }
                    .controlSize(.small)
                }
            }
            #endif

            AcknowledgementsSection()
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding()
        .onAppear {
            #if !APPSTORE
            hfToken = HuggingFaceToken.value
            #endif
            checkOllama()
        }
    }

    private func checkOllama() {
        ollamaStatus = .checking
        Task {
            let service = OllamaService()
            let available = await service.isAvailable()
            await MainActor.run {
                ollamaStatus = available ? .available : .unavailable
            }
        }
    }

    private enum OllamaStatus {
        case unknown, checking, available, unavailable
    }
}

import Sparkle
import SwiftUI

struct SettingsView: View {
    private let updater: SPUUpdater

    init() {
        self.updater = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        ).updater
    }

    @AppStorage("hf_token") private var hfToken = ""
    @AppStorage("default_model") private var defaultModel = WhisperModel.largeV3Turbo.rawValue
    @AppStorage("python_path") private var pythonPath = PythonBridge.defaultPythonPath
    @AppStorage("script_path") private var scriptPath = PythonBridge.defaultScriptPath
    @AppStorage("default_diarization") private var defaultDiarization = true
    @AppStorage("ollama_model") private var ollamaModel = OllamaModel.llama3_1.rawValue
    @AppStorage("setup_completed") private var setupCompleted = true

    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var isReinstallingPackages = false
    @State private var reinstallLog = ""

    var body: some View {
        Form {
            Section("HuggingFace") {
                SecureField("HuggingFace Token", text: $hfToken)
                    .help("Required for downloading pyannote models (diarization)")
                Text("Create a token at huggingface.co/settings/tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Default model", selection: $defaultModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }

                Toggle("Default diarization", isOn: $defaultDiarization)
                    .help("Automatically identify different speakers")
            }

            Section("LLM Summary (Ollama)") {
                Picker("Ollama Model", selection: $ollamaModel) {
                    ForEach(OllamaModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                .help("Model used to generate speaker summaries")

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
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding()
        .onAppear {
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

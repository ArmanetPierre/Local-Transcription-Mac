import SwiftUI

struct SetupView: View {
    @Bindable var manager: DependencyManager
    var onComplete: () -> Void

    @AppStorage("hf_token") private var hfToken = ""
    @State private var isScrolledToBottom = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                Text("Welcome to Voxa")
                    .font(.largeTitle.bold())

                Text("Voxa needs to set up a Python environment for audio transcription.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step 1: Python
                    SetupStepView(
                        number: 1,
                        title: String(localized: "Python 3.11+"),
                        status: manager.pythonStatus,
                        detail: pythonDetail
                    ) {
                        if case .missing = manager.pythonStatus {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Python 3.11 or later is required. Install it from:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Link("python.org/downloads",
                                     destination: URL(string: "https://www.python.org/downloads/")!)
                                    .font(.caption)
                                Text("Or via Homebrew:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("brew install python@3.12")
                                    .font(.caption.monospaced())
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                Button("Check again") {
                                    Task { await manager.checkPython() }
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    // Step 2: Python Environment
                    SetupStepView(
                        number: 2,
                        title: String(localized: "Python Environment"),
                        status: manager.venvStatus,
                        detail: venvDetail
                    ) {
                        if manager.pythonStatus == .installed && manager.venvStatus != .installed {
                            if !manager.isSettingUp {
                                Button("Set Up") {
                                    Task { await manager.runFullSetup() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                            }
                        }

                        // Live log output
                        if !manager.setupLog.isEmpty {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    Text(manager.setupLog)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id("logBottom")
                                }
                                .frame(maxHeight: 200)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onChange(of: manager.setupLog) {
                                    withAnimation {
                                        proxy.scrollTo("logBottom", anchor: .bottom)
                                    }
                                }
                            }
                        }

                        if case .failed(let error) = manager.venvStatus {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)

                            Button("Retry") {
                                Task { await manager.runFullSetup() }
                            }
                            .controlSize(.small)
                        }
                    }

                    // Step 3: FFmpeg (required)
                    SetupStepView(
                        number: 3,
                        title: "FFmpeg",
                        status: manager.ffmpegStatus,
                        detail: ffmpegDetail
                    ) {
                        if case .missing = manager.ffmpegStatus {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("FFmpeg is required for audio processing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if manager.homebrewAvailable {
                                    Button("Install FFmpeg") {
                                        Task { await manager.installFFmpeg() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                } else {
                                    Text("Install Homebrew first, then FFmpeg:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
                                        .font(.system(size: 10, design: .monospaced))
                                        .padding(6)
                                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                        .textSelection(.enabled)
                                    Text("Then restart Voxa.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button("Check again") {
                                    Task { await manager.checkFFmpeg() }
                                }
                                .controlSize(.small)
                            }
                        }

                        if case .installing = manager.ffmpegStatus {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if case .failed(let error) = manager.ffmpegStatus {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await manager.installFFmpeg() }
                            }
                            .controlSize(.small)
                        }
                    }

                    // Step 4: HuggingFace Token
                    SetupStepView(
                        number: 4,
                        title: "HuggingFace Token",
                        status: hfToken.isEmpty ? .missing : .installed,
                        detail: hfToken.isEmpty
                            ? String(localized: "Required for speaker diarization")
                            : String(localized: "Token configured")
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("HuggingFace Token", text: $hfToken)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 400)

                            HStack(spacing: 4) {
                                Text("Get your token at")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Link("huggingface.co/settings/tokens",
                                     destination: URL(string: "https://huggingface.co/settings/tokens")!)
                                    .font(.caption)
                            }

                            Text("Accept the pyannote model terms:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Link("pyannote/segmentation-3.0",
                                     destination: URL(string: "https://huggingface.co/pyannote/segmentation-3.0")!)
                                    .font(.caption)
                                Link("pyannote/speaker-diarization-3.1",
                                     destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-3.1")!)
                                    .font(.caption)
                            }
                        }
                    }

                    // Step 5: Ollama (optional)
                    SetupStepView(
                        number: 5,
                        title: String(localized: "Ollama (optional)"),
                        status: .unknown,
                        detail: String(localized: "For automatic meeting summaries")
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ollama enables AI-powered meeting summaries using local LLMs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Link("Download Ollama",
                                 destination: URL(string: "https://ollama.com")!)
                                .font(.caption)
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!manager.overallReady)
            }
            .padding(20)
        }
        .frame(minWidth: 600, minHeight: 700)
        .task {
            await manager.checkAll()
        }
    }

    // MARK: - Detail strings

    private var pythonDetail: String {
        switch manager.pythonStatus {
        case .installed:
            if let path = manager.discoveredPythonPath {
                return String(localized: "Found at \(path)")
            }
            return String(localized: "Python found")
        case .missing:
            return String(localized: "Python 3.11+ not found")
        case .checking:
            return String(localized: "Searching...")
        default:
            return ""
        }
    }

    private var venvDetail: String {
        switch manager.venvStatus {
        case .installed:
            return String(localized: "Environment ready")
        case .missing:
            return String(localized: "Not set up yet")
        case .installing(let progress):
            return progress
        case .failed:
            return String(localized: "Setup failed")
        case .checking:
            return String(localized: "Checking...")
        default:
            return ""
        }
    }

    private var ffmpegDetail: String {
        switch manager.ffmpegStatus {
        case .installed:
            return String(localized: "FFmpeg found")
        case .missing:
            return String(localized: "Required — not found")
        case .checking:
            return String(localized: "Checking...")
        case .installing(let progress):
            return progress
        case .failed:
            return String(localized: "Installation failed")
        default:
            return ""
        }
    }
}

// MARK: - Step Row Component

private struct SetupStepView<Content: View>: View {
    let number: Int
    let title: String
    let status: DependencyStatus
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                statusIcon
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                content
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange)
        case .checking, .installing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .unknown:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case .installed: .green
        case .missing: .orange
        case .checking, .installing: .blue
        case .failed: .red
        case .unknown: .secondary
        }
    }
}

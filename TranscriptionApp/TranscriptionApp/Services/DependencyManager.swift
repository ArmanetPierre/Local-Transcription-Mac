import Foundation

enum DependencyStatus: Equatable {
    case unknown
    case checking
    case installed
    case missing
    case installing(progress: String)
    case failed(error: String)

    static func == (lhs: DependencyStatus, rhs: DependencyStatus) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown), (.checking, .checking),
             (.installed, .installed), (.missing, .missing):
            return true
        case (.installing(let a), .installing(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

@Observable
final class DependencyManager {
    var pythonStatus: DependencyStatus = .unknown
    var venvStatus: DependencyStatus = .unknown
    var ffmpegStatus: DependencyStatus = .unknown
    var setupLog: String = ""
    var isSettingUp = false

    /// Path to the discovered Python 3 binary
    var discoveredPythonPath: String?

    /// True when all required dependencies are ready
    var overallReady: Bool {
        pythonStatus == .installed && venvStatus == .installed && ffmpegStatus == .installed
    }

    // MARK: - Standard Paths

    static let appSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let voxaDir = appSupport.appendingPathComponent("Voxa", isDirectory: true)
        try? FileManager.default.createDirectory(at: voxaDir, withIntermediateDirectories: true)
        return voxaDir
    }()

    static let venvDirectory: URL = {
        appSupportDirectory.appendingPathComponent(".venv", isDirectory: true)
    }()

    static let scriptsDirectory: URL = {
        appSupportDirectory.appendingPathComponent("Scripts", isDirectory: true)
    }()

    static let binDirectory: URL = {
        appSupportDirectory.appendingPathComponent("bin", isDirectory: true)
    }()

    static let venvPythonPath: String = {
        venvDirectory.appendingPathComponent("bin/python").path
    }()

    static let scriptPath: String = {
        scriptsDirectory.appendingPathComponent("transcribe_bridge.py").path
    }()

    // MARK: - Check All

    @MainActor
    func checkAll() async {
        // Check if user has custom paths that work (migration for existing users)
        let customPython = UserDefaults.standard.string(forKey: "python_path")

        // Always re-deploy scripts from bundle so updates are picked up
        try? deployScripts()
        // Always point to managed script so app updates take effect
        UserDefaults.standard.set(Self.scriptPath, forKey: "script_path")

        if let customPython,
           FileManager.default.fileExists(atPath: customPython) {
            // Existing user with valid custom Python — mark as ready
            pythonStatus = .installed
            venvStatus = .installed
            discoveredPythonPath = customPython
            await checkFFmpeg()
            return
        }

        // Check managed venv
        if FileManager.default.fileExists(atPath: Self.venvPythonPath),
           FileManager.default.fileExists(atPath: Self.scriptPath) {
            pythonStatus = .installed
            venvStatus = .installed
            discoveredPythonPath = Self.venvPythonPath
        } else {
            // Need to discover Python and set up
            await checkPython()
            if FileManager.default.fileExists(atPath: Self.venvPythonPath) {
                venvStatus = .installed
            } else {
                venvStatus = .missing
            }
        }

        await checkFFmpeg()
    }

    // MARK: - Python Detection

    @MainActor
    func checkPython() async {
        pythonStatus = .checking

        let candidatePaths = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.13",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
        ]

        // First try `which python3` to find it in PATH
        if let path = await findPythonInPath() {
            if await validatePythonVersion(path) {
                discoveredPythonPath = path
                pythonStatus = .installed
                return
            }
        }

        // Try known locations
        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if await validatePythonVersion(path) {
                discoveredPythonPath = path
                pythonStatus = .installed
                return
            }
        }

        pythonStatus = .missing
    }

    private func findPythonInPath() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "python3"]

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        if let currentPath = env["PATH"] {
            env["PATH"] = extraPaths + ":" + currentPath
        } else {
            env["PATH"] = extraPaths + ":/usr/bin:/bin"
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            // Ignore
        }
        return nil
    }

    private func validatePythonVersion(_ path: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return false }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            // Parse "Python 3.X.Y"
            let pattern = /Python (\d+)\.(\d+)/
            if let match = output.firstMatch(of: pattern) {
                let major = Int(match.1) ?? 0
                let minor = Int(match.2) ?? 0
                return major == 3 && minor >= 11
            }
        } catch {
            // Ignore
        }
        return false
    }

    // MARK: - FFmpeg Detection

    @MainActor
    func checkFFmpeg() async {
        ffmpegStatus = .checking

        let candidatePaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            Self.binDirectory.appendingPathComponent("ffmpeg").path,
        ]

        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                ffmpegStatus = .installed
                return
            }
        }

        // Also try `which ffmpeg`
        if let _ = await findInPath("ffmpeg") {
            ffmpegStatus = .installed
            return
        }

        ffmpegStatus = .missing
    }

    private func findInPath(_ command: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        if let currentPath = env["PATH"] {
            env["PATH"] = extraPaths + ":" + currentPath
        } else {
            env["PATH"] = extraPaths + ":/usr/bin:/bin"
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    return output
                }
            }
        } catch {
            // Ignore
        }
        return nil
    }

    // MARK: - FFmpeg Installation

    /// Whether Homebrew is available on the system
    var homebrewAvailable: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
    }

    private var brewPath: String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
            return "/opt/homebrew/bin/brew"
        }
        return "/usr/local/bin/brew"
    }

    @MainActor
    func installFFmpeg() async {
        ffmpegStatus = .installing(progress: String(localized: "Installing FFmpeg via Homebrew..."))
        appendLog(String(localized: "Installing FFmpeg via Homebrew..."))

        do {
            try await runProcessWithLiveOutput(
                executablePath: brewPath,
                arguments: ["install", "ffmpeg"]
            )
            appendLog(String(localized: "FFmpeg installed successfully."))
            ffmpegStatus = .installed
        } catch {
            let msg = error.localizedDescription
            appendLog("\n\u{274C} FFmpeg: \(msg)")
            ffmpegStatus = .failed(error: msg)
        }
    }

    // MARK: - Deploy Scripts

    func deployScripts() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.scriptsDirectory, withIntermediateDirectories: true)

        let scriptsToCopy = ["transcribe_bridge.py", "transcribe.py", "requirements.txt"]

        for scriptName in scriptsToCopy {
            guard let bundledURL = Bundle.main.url(forResource: scriptName, withExtension: nil)
                    ?? Bundle.main.url(
                        forResource: (scriptName as NSString).deletingPathExtension,
                        withExtension: (scriptName as NSString).pathExtension
                    )
            else {
                print("[DependencyManager] Warning: \(scriptName) not found in bundle")
                continue
            }

            let destURL = Self.scriptsDirectory.appendingPathComponent(scriptName)

            // Copy or update if bundle version is newer
            if fm.fileExists(atPath: destURL.path) {
                let bundledAttrs = try fm.attributesOfItem(atPath: bundledURL.path)
                let destAttrs = try fm.attributesOfItem(atPath: destURL.path)
                let bundledDate = bundledAttrs[.modificationDate] as? Date ?? .distantPast
                let destDate = destAttrs[.modificationDate] as? Date ?? .distantPast

                if bundledDate > destDate {
                    try fm.removeItem(at: destURL)
                    try fm.copyItem(at: bundledURL, to: destURL)
                    print("[DependencyManager] Updated \(scriptName)")
                }
            } else {
                try fm.copyItem(at: bundledURL, to: destURL)
                print("[DependencyManager] Deployed \(scriptName)")
            }
        }
    }

    // MARK: - Venv Creation & Package Installation

    @MainActor
    func createVenvAndInstall() async throws {
        guard let pythonPath = discoveredPythonPath else {
            throw SetupError.pythonNotFound
        }

        isSettingUp = true
        setupLog = ""
        venvStatus = .installing(progress: String(localized: "Creating Python environment..."))

        defer { isSettingUp = false }

        // 1. Create venv
        appendLog(String(localized: "Creating virtual environment..."))
        try await runProcess(
            executablePath: pythonPath,
            arguments: ["-m", "venv", Self.venvDirectory.path]
        )
        appendLog(String(localized: "Virtual environment created."))

        // 2. Upgrade pip
        venvStatus = .installing(progress: String(localized: "Upgrading pip..."))
        appendLog(String(localized: "Upgrading pip..."))
        let venvPip = Self.venvDirectory.appendingPathComponent("bin/pip").path
        try await runProcess(
            executablePath: venvPip,
            arguments: ["install", "--upgrade", "pip"]
        )

        // 3. Install packages from requirements.txt
        let requirementsPath = Self.scriptsDirectory.appendingPathComponent("requirements.txt").path
        guard FileManager.default.fileExists(atPath: requirementsPath) else {
            throw SetupError.requirementsNotFound
        }

        venvStatus = .installing(progress: String(localized: "Installing Python packages (this may take several minutes)..."))
        appendLog(String(localized: "Installing packages from requirements.txt..."))
        appendLog(String(localized: "This may take 5-10 minutes depending on your internet connection."))
        appendLog("")

        try await runProcessWithLiveOutput(
            executablePath: venvPip,
            arguments: ["install", "-r", requirementsPath]
        )

        appendLog("")
        appendLog(String(localized: "All packages installed successfully."))
        venvStatus = .installed

        // Update UserDefaults to point to the managed paths
        UserDefaults.standard.set(Self.venvPythonPath, forKey: "python_path")
        UserDefaults.standard.set(Self.scriptPath, forKey: "script_path")
    }

    // MARK: - Full Setup Orchestration

    @MainActor
    func runFullSetup() async {
        do {
            // 1. Deploy scripts
            appendLog(String(localized: "Deploying scripts..."))
            try deployScripts()
            appendLog(String(localized: "Scripts deployed."))
            appendLog("")

            // 2. Create venv and install packages
            try await createVenvAndInstall()

        } catch {
            let errorMsg = error.localizedDescription
            appendLog("\n\u{274C} \(errorMsg)")
            venvStatus = .failed(error: errorMsg)
        }
    }

    // MARK: - Process Execution Helpers

    private func runProcess(executablePath: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = Self.processEnvironment

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw SetupError.processExited(code: process.terminationStatus, stderr: errStr)
        }
    }

    private func runProcessWithLiveOutput(executablePath: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = Self.processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var stderrContent = ""

        // Read stdout line by line for progress
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(line.trimmingCharacters(in: .newlines))
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            stderrContent += line
            // pip progress often comes on stderr
            Task { @MainActor in
                // Filter out noisy pip lines, only show meaningful ones
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("  ") {
                    // Show downloading/installing progress
                    if trimmed.contains("Downloading") || trimmed.contains("Installing") ||
                       trimmed.contains("Successfully") || trimmed.contains("Collecting") ||
                       trimmed.contains("Building") || trimmed.contains("ERROR") {
                        self.appendLog(trimmed)
                    }
                }
            }
        }

        try process.run()

        // Wait for process in background
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            throw SetupError.processExited(code: process.terminationStatus, stderr: stderrContent)
        }
    }

    @MainActor
    private func appendLog(_ text: String) {
        if !setupLog.isEmpty {
            setupLog += "\n"
        }
        setupLog += text
    }

    private static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        if let currentPath = env["PATH"] {
            env["PATH"] = extraPaths + ":" + currentPath
        } else {
            env["PATH"] = extraPaths + ":/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return env
    }

    // MARK: - Errors

    enum SetupError: LocalizedError {
        case pythonNotFound
        case requirementsNotFound
        case processExited(code: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                String(localized: "Python 3.11+ not found on this system.")
            case .requirementsNotFound:
                String(localized: "requirements.txt not found. Try reinstalling Voxa.")
            case .processExited(let code, let stderr):
                String(localized: "Process exited with code \(code): \(stderr)")
            }
        }
    }
}

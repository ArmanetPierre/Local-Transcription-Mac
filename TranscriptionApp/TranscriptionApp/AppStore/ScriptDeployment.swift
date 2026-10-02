import Foundation

/// Version App Store : seul le script du serveur MCP est deploye (pas de Python
/// pour la transcription). Il est execute par Claude Code, en dehors de l'app.
enum ScriptDeployment {
    static func deployMCPScript() {
        guard let bundled = Bundle.main.url(forResource: "voxa_mcp", withExtension: "py") else { return }
        let destination = AppPaths.scriptsDirectory.appendingPathComponent("voxa_mcp.py")
        try? FileManager.default.createDirectory(at: AppPaths.scriptsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: bundled, to: destination)
    }
}

import AppKit
import Foundation

/// Version App Store (sandbox) : dossiers que l'utilisateur autorise Claude Code
/// (via le MCP) a faire transcrire. L'autorisation est memorisee par des signets
/// "security-scoped" : elle survit aux redemarrages.
@Observable
final class FolderAccess {
    static let shared = FolderAccess()
    private static let defaultsKey = "mcp_authorized_folders"

    private(set) var folders: [URL] = []
    private var bookmarks: [Data]

    init() {
        bookmarks = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Data] ?? []
        folders = bookmarks.compactMap(Self.resolve)
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Demande a l'utilisateur un dossier a autoriser
    @MainActor
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Allow")
        panel.message = String(localized: "Choose the folders whose recordings Claude Code may transcribe with Voxa.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard !folders.contains(url),
                  let data = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            bookmarks.append(data)
            folders.append(url)
        }
        save()
    }

    func remove(_ url: URL) {
        guard let index = folders.firstIndex(of: url) else { return }
        folders.remove(at: index)
        bookmarks.remove(at: index)
        save()
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: Self.defaultsKey)
    }

    /// Dossier autorise contenant ce fichier (nil si aucun)
    func authorizedFolder(for file: URL) -> URL? {
        let path = file.standardizedFileURL.path
        return folders.first { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Execute `body` avec l'acces au fichier (via son dossier autorise)
    func withAccess<T>(to file: URL, _ body: () async throws -> T) async throws -> T {
        // Fichiers deja dans le conteneur de l'app : toujours accessibles
        if file.standardizedFileURL.path.hasPrefix(NSHomeDirectory() + "/") {
            return try await body()
        }
        guard let folder = authorizedFolder(for: file) else {
            throw FolderAccessError.notAuthorized(file.deletingLastPathComponent().path)
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}

enum FolderAccessError: LocalizedError {
    case notAuthorized(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let folder):
            "Voxa is not allowed to read \(folder). Add this folder (or a parent) in Voxa > Settings > Claude Code (MCP) > Allowed folders, then retry."
        }
    }
}

import Foundation

/// Dossiers de Voxa. Dans la version App Store (sandbox), macOS redirige
/// automatiquement Application Support vers le conteneur de l'app.
enum AppPaths {
    static let appSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let voxaDir = appSupport.appendingPathComponent("Voxa", isDirectory: true)
        try? FileManager.default.createDirectory(at: voxaDir, withIntermediateDirectories: true)
        return voxaDir
    }()

    static let scriptsDirectory: URL = {
        appSupportDirectory.appendingPathComponent("Scripts", isDirectory: true)
    }()

    /// Modeles du moteur natif (WhisperKit, SpeakerKit)
    static let modelsDirectory: URL = {
        appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }()
}

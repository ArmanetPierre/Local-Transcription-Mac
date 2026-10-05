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

    /// Enregistrements en cours ou interrompus (un dossier par session). Hors du dossier
    /// temporaire : macOS le vide, alors qu'une session interrompue doit etre recuperee.
    static let recordingsDirectory: URL = {
        let dir = appSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

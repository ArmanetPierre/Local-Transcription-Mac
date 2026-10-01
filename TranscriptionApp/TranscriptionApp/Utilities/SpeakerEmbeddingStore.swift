import Foundation

/// Gere les embeddings vocaux des speakers pour le matching automatique.
/// - Projet : embeddings recus du Python pour chaque transcription, gardes sur
///   disque pour pouvoir nommer un intervenant plus tard (meme apres un redemarrage)
/// - Saved : embeddings associes a des noms confirmes, utilises pour la reconnaissance
final class SpeakerEmbeddingStore {
    static let shared = SpeakerEmbeddingStore()

    // Embeddings par projet (UUID) puis par label (SPEAKER_00...)
    private var projectEmbeddings: [UUID: [String: [Double]]]
    // Matchs automatiques : seulement utiles juste apres la transcription
    private var pendingMatches: [UUID: [String: String]] = [:]
    private let lock = NSLock()

    init() {
        projectEmbeddings = Self.loadProjectEmbeddings()
    }

    /// Chemin du fichier JSON global des embeddings sauvegardes
    static var embeddingsFilePath: String {
        voxaDirectory.appendingPathComponent("speaker_embeddings.json").path
    }

    /// Embeddings de chaque transcription, en attente d'un nom
    static var projectEmbeddingsFileURL: URL {
        voxaDirectory.appendingPathComponent("project_embeddings.json")
    }

    private static var voxaDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Voxa", isDirectory: true)
    }

    // MARK: - Embeddings d'un projet (from diarization)

    /// Stocker les embeddings et matchs recus du Python pour un projet
    func setPending(projectId: UUID, embeddings: [String: [Double]], matches: [String: String]) {
        lock.lock()
        projectEmbeddings[projectId] = embeddings
        pendingMatches[projectId] = matches
        let snapshot = projectEmbeddings
        lock.unlock()
        Self.saveProjectEmbeddings(snapshot)
        print("[EmbeddingStore] setPending: \(embeddings.count) embeddings, \(matches.count) matches pour projet \(projectId)")
    }

    /// Recuperer les matchs automatiques pour un projet
    func getPendingMatches(projectId: UUID) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return pendingMatches[projectId]
    }

    /// Recuperer les embeddings d'un projet
    func getPendingEmbeddings(projectId: UUID) -> [String: [Double]]? {
        lock.lock()
        defer { lock.unlock() }
        return projectEmbeddings[projectId]
    }

    /// Oublier les embeddings d'un projet (projet supprime)
    func clearPending(projectId: UUID) {
        lock.lock()
        let removed = projectEmbeddings.removeValue(forKey: projectId) != nil
        pendingMatches.removeValue(forKey: projectId)
        let snapshot = projectEmbeddings
        lock.unlock()
        if removed {
            Self.saveProjectEmbeddings(snapshot)
        }
    }

    private static func loadProjectEmbeddings() -> [UUID: [String: [Double]]] {
        guard let data = try? Data(contentsOf: projectEmbeddingsFileURL),
              let decoded = try? JSONDecoder().decode([String: [String: [Double]]].self, from: data) else {
            return [:]
        }
        var result: [UUID: [String: [Double]]] = [:]
        for (key, value) in decoded {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    private static func saveProjectEmbeddings(_ embeddings: [UUID: [String: [Double]]]) {
        let encodable = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        try? FileManager.default.createDirectory(at: voxaDirectory, withIntermediateDirectories: true)
        try? data.write(to: projectEmbeddingsFileURL, options: .atomic)
    }

    // MARK: - Confirmed (save to disk)

    /// Sauvegarder les embeddings avec les noms confirmes par l'utilisateur.
    /// labelToName : ["SPEAKER_00": "Pierre", "SPEAKER_01": "Jean"]
    func confirmSpeakerNames(projectId: UUID, labelToName: [String: String]) {
        guard let embeddings = getPendingEmbeddings(projectId: projectId) else {
            print("[EmbeddingStore] confirmSpeakerNames: aucun embedding en attente pour \(projectId)")
            return
        }

        var saved = loadSavedEmbeddings()

        for (label, name) in labelToName {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let embedding = embeddings[label] else { continue }
            saved[trimmed] = embedding
            print("[EmbeddingStore] Sauvegarde embedding pour '\(trimmed)' (dim=\(embedding.count))")
        }

        saveToDisk(saved)
        print("[EmbeddingStore] \(saved.count) speakers sauvegardes au total")
    }

    // MARK: - File I/O

    private func loadSavedEmbeddings() -> [String: [Double]] {
        let path = Self.embeddingsFilePath
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveToDisk(_ embeddings: [String: [Double]]) {
        let path = Self.embeddingsFilePath
        let dirPath = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dirPath,
            withIntermediateDirectories: true
        )

        guard let data = try? JSONEncoder().encode(embeddings) else {
            print("[EmbeddingStore] ERREUR: impossible d'encoder les embeddings")
            return
        }
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

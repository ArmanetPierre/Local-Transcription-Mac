import Foundation

/// Gere les embeddings vocaux des speakers pour le matching automatique.
/// - Pending : embeddings recus du Python (pas encore confirmes par l'utilisateur)
/// - Saved : embeddings sur disque associes a des noms confirmes
final class SpeakerEmbeddingStore {
    static let shared = SpeakerEmbeddingStore()

    // Pending embeddings from diarization, keyed by project UUID
    private var pendingEmbeddings: [UUID: [String: [Double]]] = [:]
    private var pendingMatches: [UUID: [String: String]] = [:]

    /// Chemin du fichier JSON global des embeddings sauvegardes
    static var embeddingsFilePath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Voxa/speaker_embeddings.json")
            .path
    }

    // MARK: - Pending (from diarization, before user confirmation)

    /// Stocker les embeddings et matchs recus du Python pour un projet
    func setPending(projectId: UUID, embeddings: [String: [Double]], matches: [String: String]) {
        pendingEmbeddings[projectId] = embeddings
        pendingMatches[projectId] = matches
        print("[EmbeddingStore] setPending: \(embeddings.count) embeddings, \(matches.count) matches pour projet \(projectId)")
    }

    /// Recuperer les matchs automatiques pour un projet
    func getPendingMatches(projectId: UUID) -> [String: String]? {
        pendingMatches[projectId]
    }

    /// Recuperer les embeddings en attente pour un projet
    func getPendingEmbeddings(projectId: UUID) -> [String: [Double]]? {
        pendingEmbeddings[projectId]
    }

    /// Nettoyer les donnees temporaires d'un projet
    func clearPending(projectId: UUID) {
        pendingEmbeddings.removeValue(forKey: projectId)
        pendingMatches.removeValue(forKey: projectId)
    }

    // MARK: - Confirmed (save to disk)

    /// Sauvegarder les embeddings avec les noms confirmes par l'utilisateur.
    /// labelToName : ["SPEAKER_00": "Pierre", "SPEAKER_01": "Jean"]
    func confirmSpeakerNames(projectId: UUID, labelToName: [String: String]) {
        guard let embeddings = pendingEmbeddings[projectId] else {
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
        clearPending(projectId: projectId)
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

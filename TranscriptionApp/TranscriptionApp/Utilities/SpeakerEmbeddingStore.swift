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

    // MARK: - Base de voix (noms confirmes)

    /// Nombre maximum d'empreintes gardees par personne (les plus anciennes partent)
    static let maxSamplesPerSpeaker = 10

    /// Sauvegarder les empreintes des intervenants nommes par l'utilisateur.
    /// labelToName : ["SPEAKER_00": "Pierre", "SPEAKER_01": "Jean"]
    ///
    /// Chaque personne garde plusieurs empreintes (une par transcription) : une voix
    /// en reunion et la meme en visio se ressemblent peu, il faut connaitre les deux.
    /// Renommer un intervenant deplace son empreinte ; un nom vide la retire.
    func confirmSpeakerNames(projectId: UUID, labelToName: [String: String]) {
        guard let embeddings = getPendingEmbeddings(projectId: projectId) else {
            print("[EmbeddingStore] confirmSpeakerNames: aucun embedding pour \(projectId)")
            return
        }

        var gallery = loadGallery()
        for (label, name) in labelToName {
            let source = "\(projectId.uuidString):\(label)"
            gallery.removeSamples(source: source)
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let embedding = embeddings[label] else { continue }
            gallery.add(
                VoiceSample(embedding: embedding, source: source, added: Date()),
                to: trimmed,
                limit: Self.maxSamplesPerSpeaker
            )
            print("[EmbeddingStore] Empreinte enregistree pour '\(trimmed)' (dim=\(embedding.count))")
        }
        saveGallery(gallery)
        print("[EmbeddingStore] \(gallery.speakers.count) personnes connues")
    }

    // MARK: - Gestion des voix connues (Reglages)

    /// Personnes connues et nombre d'empreintes, triees par nom
    func knownSpeakers() -> [(name: String, samples: Int)] {
        loadGallery().speakers
            .map { (name: $0.key, samples: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Renommer une personne ; si le nouveau nom existe deja, les deux sont fusionnees.
    func renameSpeaker(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        var gallery = loadGallery()
        guard let samples = gallery.speakers.removeValue(forKey: oldName) else { return }
        for sample in samples {
            gallery.add(sample, to: trimmed, limit: Self.maxSamplesPerSpeaker)
        }
        saveGallery(gallery)
    }

    /// Oublier la voix d'une personne
    func deleteSpeaker(_ name: String) {
        var gallery = loadGallery()
        gallery.speakers.removeValue(forKey: name)
        saveGallery(gallery)
    }

    // MARK: - File I/O

    func loadGallery() -> VoiceGallery {
        guard let data = FileManager.default.contents(atPath: Self.embeddingsFilePath) else {
            return VoiceGallery()
        }
        return VoiceGallery.decode(data)
    }

    private func saveGallery(_ gallery: VoiceGallery) {
        let url = URL(fileURLWithPath: Self.embeddingsFilePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? gallery.encoded() else {
            print("[EmbeddingStore] ERREUR: impossible d'encoder la base de voix")
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Format de la base de voix

/// Une empreinte vocale, avec la transcription d'ou elle vient
struct VoiceSample: Codable, Equatable {
    var embedding: [Double]
    /// "<uuid du projet>:<label>" : evite les doublons quand on renomme
    var source: String?
    var added: Date?
}

/// Base de voix (speaker_embeddings.json).
/// v2 : {"version": 2, "speakers": {"Nom": [VoiceSample, ...]}}
/// v1 (Voxa <= 1.4) : {"Nom": [floats]}, convertie a la lecture.
struct VoiceGallery: Codable, Equatable {
    var version = 2
    var speakers: [String: [VoiceSample]] = [:]

    static func decode(_ data: Data) -> VoiceGallery {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let v2 = try? decoder.decode(VoiceGallery.self, from: data), v2.version == 2 {
            return v2
        }
        if let v1 = try? decoder.decode([String: [Double]].self, from: data) {
            var gallery = VoiceGallery()
            for (name, embedding) in v1 {
                gallery.speakers[name] = [VoiceSample(embedding: embedding, source: nil, added: nil)]
            }
            return gallery
        }
        return VoiceGallery()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    mutating func add(_ sample: VoiceSample, to name: String, limit: Int) {
        var samples = speakers[name] ?? []
        samples.append(sample)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
        speakers[name] = samples
    }

    /// Retirer l'empreinte venant d'un intervenant precis (chez n'importe quelle personne)
    mutating func removeSamples(source: String) {
        for (name, samples) in speakers {
            let kept = samples.filter { $0.source != source }
            if kept.isEmpty {
                speakers.removeValue(forKey: name)
            } else if kept.count != samples.count {
                speakers[name] = kept
            }
        }
    }
}

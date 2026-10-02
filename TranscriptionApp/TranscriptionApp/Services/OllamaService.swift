import Foundation

enum OllamaError: LocalizedError {
    case serverUnavailable
    case invalidResponse(statusCode: Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            "Ollama n'est pas accessible sur localhost:11434. Lancez 'ollama serve' dans un terminal."
        case .invalidResponse(let code):
            "Reponse invalide du serveur Ollama (code \(code))"
        case .decodingError(let msg):
            "Erreur de decodage: \(msg)"
        }
    }
}

@Observable
final class OllamaService {
    var isGenerating = false
    var currentSpeaker: String?
    var progress: Double = 0

    private let baseURL: String

    /// Processus du serveur Ollama lance par l'app (nil si lance exterieurement)
    private static var serverProcess: Process?
    private static var isStartingServer = false

    init(baseURL: String = "http://127.0.0.1:11434") {
        self.baseURL = baseURL
    }

    // MARK: - Health Check

    func isAvailable() async -> Bool {
        guard let url = URL(string: baseURL) else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Server Management

    /// Trouve le binaire ollama sur le systeme
    static func findOllamaBinary() -> String? {
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
            "\(NSHomeDirectory())/.local/bin/ollama",
            "\(NSHomeDirectory())/bin/ollama",
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// S'assure qu'Ollama est en cours d'execution. Demarre le serveur si necessaire.
    func ensureRunning() async -> Bool {
        #if APPSTORE
        // Version App Store (sandbox) : impossible de lancer ollama, on utilise
        // seulement un serveur deja demarre par l'utilisateur.
        return await isAvailable()
        #else
        return await ensureRunningLaunchingIfNeeded()
        #endif
    }

    private func ensureRunningLaunchingIfNeeded() async -> Bool {
        // 1. Verifier si deja disponible
        if await isAvailable() {
            print("[Ollama] Serveur deja disponible")
            return true
        }

        // 2. Eviter les demarrages multiples
        guard !Self.isStartingServer else {
            print("[Ollama] Demarrage deja en cours, attente...")
            return await waitForServer(timeout: 30)
        }

        // 3. Trouver le binaire
        guard let binaryPath = Self.findOllamaBinary() else {
            print("[Ollama] ERREUR: binaire ollama introuvable")
            return false
        }

        print("[Ollama] Demarrage du serveur: \(binaryPath) serve")
        Self.isStartingServer = true
        defer { Self.isStartingServer = false }

        // 4. Lancer le processus
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve"]
        // Rediriger stdout/stderr pour eviter la pollution de la console Xcode
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Variables d'environnement (PATH pour les dependances)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        process.environment = env

        do {
            try process.run()
            Self.serverProcess = process
            print("[Ollama] Processus lance (PID: \(process.processIdentifier))")
        } catch {
            print("[Ollama] ERREUR lancement: \(error)")
            return false
        }

        // 5. Attendre que le serveur soit pret
        return await waitForServer(timeout: 15)
    }

    /// Attend que le serveur Ollama soit pret (polling)
    private func waitForServer(timeout: TimeInterval) async -> Bool {
        let start = Date()
        let pollInterval: UInt64 = 500_000_000 // 0.5s

        while Date().timeIntervalSince(start) < timeout {
            if await isAvailable() {
                print("[Ollama] Serveur pret apres \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return true
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        print("[Ollama] TIMEOUT apres \(timeout)s - serveur non disponible")
        return false
    }

    /// Arrete le serveur Ollama si lance par l'app
    static func stopServer() {
        guard let process = serverProcess, process.isRunning else { return }
        print("[Ollama] Arret du serveur (PID: \(process.processIdentifier))")
        process.terminate()
        serverProcess = nil
    }

    // MARK: - Model Management

    /// Proprietes observables pour le telechargement de modele
    var isPulling = false
    var pullProgress: Double = 0
    var pullModelName: String?

    /// Verifie si un modele est disponible localement
    func isModelAvailable(_ model: OllamaModel) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else { return false }

            let modelName = model.rawValue
            return models.contains { entry in
                guard let name = entry["name"] as? String else { return false }
                // Ollama retourne "llama3.1:8b" ou "llama3.1:latest" etc.
                return name == modelName || name.hasPrefix(modelName.split(separator: ":").first.map(String.init) ?? "")
                    && name.hasSuffix(modelName.split(separator: ":").last.map(String.init) ?? "")
            }
        } catch {
            print("[Ollama] Erreur verification modele: \(error)")
            return false
        }
    }

    /// Telecharge un modele si necessaire. Retourne true si le modele est disponible apres l'operation.
    func ensureModelAvailable(_ model: OllamaModel) async -> Bool {
        // Verifier d'abord si deja present
        if await isModelAvailable(model) {
            print("[Ollama] Modele \(model.rawValue) deja disponible")
            return true
        }

        print("[Ollama] Modele \(model.rawValue) absent, telechargement...")
        return await pullModel(model)
    }

    /// Telecharge un modele via l'API Ollama avec suivi de progression
    private func pullModel(_ model: OllamaModel) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/pull") else { return false }

        await MainActor.run {
            isPulling = true
            pullProgress = 0
            pullModelName = model.displayName
        }

        defer {
            Task { @MainActor in
                self.isPulling = false
                self.pullModelName = nil
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600 // Les modeles peuvent etre volumineux

        let body: [String: Any] = [
            "name": model.rawValue,
            "stream": true,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[Ollama] Pull echoue: status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return false
            }

            // Lire le stream JSON ligne par ligne
            for try await line in bytes.lines {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }

                if let status = json["status"] as? String {
                    print("[Ollama] Pull: \(status)")
                }

                // Progression basee sur total/completed
                if let total = json["total"] as? Double, total > 0,
                   let completed = json["completed"] as? Double
                {
                    let progress = completed / total
                    await MainActor.run {
                        self.pullProgress = progress
                    }
                }

                // Verifier les erreurs
                if let error = json["error"] as? String {
                    print("[Ollama] Pull ERREUR: \(error)")
                    return false
                }
            }

            await MainActor.run {
                self.pullProgress = 1.0
            }

            print("[Ollama] Modele \(model.rawValue) telecharge avec succes")
            return true
        } catch {
            print("[Ollama] Pull ERREUR: \(error)")
            return false
        }
    }

    // MARK: - Generate per speaker

    func generateSpeakerSummary(
        speakerName: String,
        segmentsText: String,
        model: OllamaModel = .llama3_1
    ) async throws -> String {
        let truncated = truncateForLLM(segmentsText)

        let prompt = """
        Tu es un assistant qui analyse des transcriptions audio.
        Voici l'ensemble des interventions de "\(speakerName)" dans une conversation transcrite.

        Texte de \(speakerName) :
        ---
        \(truncated)
        ---

        Fais une synthese structuree de ce que \(speakerName) a dit. \
        Identifie les points cles, les arguments principaux et les sujets abordes. \
        Reponds en francais. Sois concis mais complet (3 a 5 paragraphes maximum).
        """

        return try await generate(prompt: prompt, model: model)
    }

    // MARK: - Generate all summaries

    func generateAllSummaries(
        project: TranscriptionProject,
        model: OllamaModel = .llama3_1
    ) async throws -> [String: String] {
        let speakers = project.uniqueSpeakers
        var summaries: [String: String] = [:]

        await MainActor.run {
            isGenerating = true
            progress = 0
        }

        defer {
            Task { @MainActor in
                self.isGenerating = false
                self.currentSpeaker = nil
            }
        }

        for (index, speakerLabel) in speakers.enumerated() {
            await MainActor.run {
                currentSpeaker = speakerLabel
                progress = Double(index) / Double(speakers.count)
            }

            let segments = project.sortedSegments.filter {
                $0.speakerLabel == speakerLabel
            }
            guard !segments.isEmpty else { continue }

            let combinedText = segments
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")

            // Ignorer les speakers avec trop peu de contenu (artefacts de sous-titrage, etc.)
            let wordCount = combinedText.split(separator: " ").count
            guard wordCount >= 30 else {
                print("[Synthese] Speaker \(speakerLabel) ignore (\(wordCount) mots < 30)")
                continue
            }

            let name = project.displayName(for: speakerLabel)
            let summary = try await generateSpeakerSummary(
                speakerName: name,
                segmentsText: combinedText,
                model: model
            )
            summaries[speakerLabel] = summary
        }

        await MainActor.run {
            progress = 1.0
        }

        return summaries
    }

    // MARK: - Generate Meeting Report

    func generateMeetingReport(
        project: TranscriptionProject,
        model: OllamaModel = .llama3_1
    ) async throws -> String {
        // Identifier les speakers significatifs (>= 30 mots)
        let significantSpeakers = project.uniqueSpeakers.filter { label in
            let wordCount = project.sortedSegments
                .filter { $0.speakerLabel == label }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .split(separator: " ").count
            return wordCount >= 30
        }
        let speakerNames = significantSpeakers.map { project.displayName(for: $0) }
        let speakerList = speakerNames.joined(separator: ", ")

        // Filtrer les segments des speakers significatifs uniquement
        let significantSegments = project.sortedSegments.filter { seg in
            guard let label = seg.speakerLabel else { return false }
            return significantSpeakers.contains(label)
        }

        let formattedTranscription = significantSegments.map { seg in
            let speaker = project.displayName(for: seg.speakerLabel ?? "Inconnu")
            let ts = formatTimestamp(seg.startTime)
            return "[\(ts)] \(speaker) : \(seg.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")

        let truncated = truncateForLLM(formattedTranscription, maxWords: 8000)

        let prompt = """
        Tu es un assistant specialise dans la redaction de comptes rendus de reunions.
        Voici la transcription complete d'une reunion avec \(speakerNames.count) participants : \(speakerList).

        Transcription :
        ---
        \(truncated)
        ---

        Redige un compte rendu structure de cette reunion avec les sections suivantes :
        1. **Contexte** : De quoi parle cette reunion ? Quel est le sujet principal ?
        2. **Participants** : Liste des intervenants et leur role apparent dans la discussion.
        3. **Points cles** : Les sujets importants abordes, avec les arguments de chaque partie.
        4. **Decisions** : Les decisions prises ou les consensus atteints (s'il y en a).
        5. **Actions a mener** : Les prochaines etapes mentionnees ou les taches assignees (s'il y en a).
        6. **Conclusion** : Resume en 2-3 phrases de l'ensemble.

        Reponds en francais. Sois factuel et concis. Utilise du markdown pour la mise en forme.
        """

        return try await generate(prompt: prompt, model: model, maxTokens: 4096)
    }

    // MARK: - Low-Level API

    private func generate(prompt: String, model: OllamaModel, maxTokens: Int = 2048) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.serverUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": model.rawValue,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": maxTokens
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverUnavailable
        }
        guard httpResponse.statusCode == 200 else {
            throw OllamaError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw OllamaError.decodingError("Champ 'response' manquant dans la reponse Ollama")
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Helpers

    private func truncateForLLM(_ text: String, maxWords: Int = 6000) -> String {
        let words = text.split(separator: " ")
        if words.count <= maxWords { return text }
        return words.prefix(maxWords).joined(separator: " ") + "\n[... tronque]"
    }
}

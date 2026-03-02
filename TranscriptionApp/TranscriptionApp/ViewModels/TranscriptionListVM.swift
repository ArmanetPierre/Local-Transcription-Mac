import Foundation
import SwiftData
import UniformTypeIdentifiers

@Observable
final class TranscriptionListVM {
    var searchText = ""
    var isImporting = false
    var batchQueue: [URL] = []
    var currentProject: TranscriptionProject?
    let estimationService = EstimationService()

    private let bridge = PythonBridge()
    private var processingTask: Task<Void, Never>?

    var isProcessing: Bool {
        bridge.isRunning
    }

    // MARK: - Import

    static let supportedTypes: [UTType] = [
        .audio,
        .mpeg4Audio,
        .wav,
        .mp3,
        .aiff,
        UTType("public.m4a") ?? .audio,
        UTType("com.apple.m4a-audio") ?? .audio,
    ]

    /// Repertoire persistant pour stocker les fichiers audio importes
    private static var audioStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let audioDir = appSupport
            .appendingPathComponent("Voxa", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return audioDir
    }

    /// Copie un fichier audio vers le stockage persistant de l'app.
    /// Gere les URLs security-scoped (file importer) et les fichiers temporaires (drag & drop).
    private func copyAudioToStorage(_ sourceURL: URL) -> URL {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        // Nom unique pour eviter les collisions : UUID_nomOriginal.ext
        let fileName = "\(UUID().uuidString)_\(sourceURL.lastPathComponent)"
        let destURL = Self.audioStorageDirectory.appendingPathComponent(fileName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            print("[ListVM] Audio copie vers: \(destURL.path)")
            return destURL
        } catch {
            print("[ListVM] ERREUR copie audio: \(error) - utilisation du chemin original")
            return sourceURL
        }
    }

    func importFiles(_ urls: [URL], modelContext: ModelContext) {
        let newURLs = urls.filter { url in
            !batchQueue.contains(url)
        }

        print("[ListVM] Import de \(newURLs.count) fichier(s), queue totale: \(batchQueue.count + newURLs.count)")
        for url in newURLs {
            print("[ListVM]   → \(url.lastPathComponent)")
            // Copier le fichier vers le stockage persistant (les URLs temporaires
            // du drag & drop ou fileImporter sont nettoyees apres l'import)
            let storedURL = copyAudioToStorage(url)
            batchQueue.append(storedURL)
            let project = TranscriptionProject.create(audioURL: storedURL)
            modelContext.insert(project)
        }

        if !bridge.isRunning {
            processNext(modelContext: modelContext)
        }
    }

    // MARK: - Processing

    func processNext(modelContext: ModelContext) {
        guard !batchQueue.isEmpty else {
            print("[ListVM] Queue vide, rien a traiter")
            return
        }
        let url = batchQueue.removeFirst()
        print("[ListVM] processNext: \(url.lastPathComponent), restant en queue: \(batchQueue.count)")

        // Trouver le projet correspondant
        let path = url.path
        let descriptor = FetchDescriptor<TranscriptionProject>(
            predicate: #Predicate { $0.audioFilePath == path && $0.statusRaw == "pending" }
        )
        guard let project = try? modelContext.fetch(descriptor).first else {
            print("[ListVM] ERREUR: projet introuvable pour \(url.lastPathComponent)")
            return
        }
        print("[ListVM] Projet trouve: \(project.title) (id: \(project.id))")
        currentProject = project

        processingTask = Task {
            await runTranscription(project: project, modelContext: modelContext)
            // Traiter le suivant dans la queue
            processNext(modelContext: modelContext)
        }
    }

    @MainActor
    func runTranscription(project: TranscriptionProject, modelContext: ModelContext) async {
        let startTime = Date()

        print("[ListVM] === DEBUT TRANSCRIPTION ===")
        print("[ListVM] Projet: \(project.title) (id: \(project.id))")
        print("[ListVM] Audio: \(project.audioFilePath)")
        print("[ListVM] Modele: \(project.whisperModel), diarize: \(project.diarizationEnabled)")
        print("[ListVM] Langue: \(project.language ?? "auto")")

        project.status = .transcribing
        project.progressPercent = 0
        estimationService.startTracking()

        let hfToken = UserDefaults.standard.string(forKey: "hf_token") ?? ""

        let stream = bridge.transcribe(
            audioPath: project.audioFilePath,
            model: WhisperModel(rawValue: project.whisperModel) ?? .largeV3Turbo,
            language: project.language,
            diarize: project.diarizationEnabled,
            hfToken: hfToken
        )

        var messageCount = 0
        var receivedResult = false

        do {
            for try await message in stream {
                messageCount += 1
                switch message {
                case .initialize(let msg):
                    print("[ListVM] ← initialize: duree=\(msg.audioDurationSec)s, langue=\(msg.language ?? "nil")")
                    project.audioDurationSec = msg.audioDurationSec
                    if let lang = msg.language {
                        project.language = lang
                    }

                case .stepStart(let msg):
                    print("[ListVM] ← stepStart: \(msg.step)")
                    project.currentStep = msg.step
                    project.progressPercent = 0 // Reset par etape
                    switch msg.step {
                    case "transcription": project.status = .transcribing
                    case "diarization": project.status = .diarizing
                    case "speaker_assignment": project.status = .merging
                    default: break
                    }

                case .progress(let msg):
                    // Pourcentage en 0-100 pour l'affichage
                    let percentValue = msg.percent > 1.0 ? msg.percent : msg.percent * 100.0
                    project.progressPercent = min(percentValue, 100.0)

                    // Progression globale (0-1) pour l'estimation du temps total
                    // Poids : transcription ~70%, diarisation ~25%, attribution ~5%
                    let stepProgress = min(percentValue / 100.0, 1.0)
                    let globalProgress: Double
                    if project.diarizationEnabled {
                        switch project.currentStep {
                        case "transcription":
                            globalProgress = stepProgress * 0.70
                        case "diarization":
                            globalProgress = 0.70 + stepProgress * 0.25
                        case "speaker_assignment":
                            globalProgress = 0.95 + stepProgress * 0.05
                        default:
                            globalProgress = stepProgress
                        }
                    } else {
                        globalProgress = stepProgress
                    }
                    estimationService.update(progress: globalProgress)

                    // Log progress seulement tous les 10%
                    if Int(percentValue) % 10 == 0 {
                        print("[ListVM] ← progress: \(msg.step) \(Int(percentValue))%")
                    }

                case .stepComplete(let msg):
                    print("[ListVM] ← stepComplete: \(msg.step) en \(String(format: "%.1f", msg.durationSec))s")
                    switch msg.step {
                    case "transcription":
                        project.transcriptionDurationSec = msg.durationSec
                        if let lang = msg.detectedLanguage {
                            print("[ListVM]   langue detectee: \(lang)")
                            project.language = lang
                        }
                    case "diarization":
                        project.diarizationDurationSec = msg.durationSec
                    default:
                        break
                    }

                case .result(let msg):
                    receivedResult = true
                    print("[ListVM] ← result: \(msg.segments.count) segments, langue=\(msg.language), total=\(String(format: "%.1f", msg.totalDurationSec))s")

                    // Supprimer les anciens segments
                    let oldCount = project.segments.count
                    for seg in project.segments {
                        modelContext.delete(seg)
                    }
                    project.segments = []
                    if oldCount > 0 {
                        print("[ListVM]   \(oldCount) anciens segments supprimes")
                    }

                    // Creer les nouveaux segments
                    for resultSeg in msg.segments {
                        let segment = Segment.create(from: resultSeg, project: project)
                        modelContext.insert(segment)
                        project.segments.append(segment)
                    }
                    print("[ListVM]   \(project.segments.count) segments crees, speakers: \(project.uniqueSpeakers)")

                    project.language = msg.language
                    project.totalProcessingDurationSec = msg.totalDurationSec
                    project.completedAt = Date()

                    // Si diarisation active et plusieurs speakers → ecran identification
                    if project.diarizationEnabled && project.uniqueSpeakers.count > 1 {
                        print("[ListVM]   → status = awaitingSpeakerNames (\(project.uniqueSpeakers.count) speakers)")
                        project.status = .awaitingSpeakerNames
                    } else {
                        print("[ListVM]   → status = completed")
                        project.status = .completed
                    }

                case .error(let msg):
                    print("[ListVM] ← error: fatal=\(msg.fatal), message=\(msg.message)")
                    if msg.fatal {
                        project.status = .failed
                        project.errorMessage = msg.message
                    }

                case .log(let msg):
                    print("[ListVM] ← log [\(msg.level)]: \(msg.message)")
                }
            }

            let elapsed = Date().timeIntervalSince(startTime)
            print("[ListVM] Stream termine. Messages recus: \(messageCount), result recu: \(receivedResult), duree: \(String(format: "%.1f", elapsed))s")
            print("[ListVM] Status actuel: \(project.status), segments: \(project.segments.count)")

            // Si on arrive ici sans result, verifier le statut
            if project.status != .completed && project.status != .failed
                && project.status != .awaitingSpeakerNames {
                if project.segments.isEmpty {
                    // Le processus s'est termine sans produire de segments
                    print("[ListVM] ALERTE: stream termine sans .result et 0 segments → failed")
                    project.status = .failed
                    project.errorMessage = "La transcription s'est terminee sans produire de resultats. Verifiez le fichier audio."
                } else {
                    print("[ListVM] Stream termine sans .result mais \(project.segments.count) segments existants → completed")
                    project.status = .completed
                }
                project.completedAt = Date()
            }

            print("[ListVM] === FIN TRANSCRIPTION: \(project.status) ===")
            currentProject = nil
            estimationService.reset()

        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            print("[ListVM] EXCEPTION apres \(String(format: "%.1f", elapsed))s et \(messageCount) messages: \(error)")
            print("[ListVM] Error localizedDescription: \(error.localizedDescription)")
            // Ne pas ecraser si on a deja recu une erreur JSON du script
            if project.status != .failed {
                project.status = .failed
            }
            if project.errorMessage == nil {
                project.errorMessage = error.localizedDescription
            }
            print("[ListVM] === FIN TRANSCRIPTION (erreur): \(project.status) ===")
            currentProject = nil
            estimationService.reset()
        }
    }

    func cancelCurrent() {
        bridge.cancel()
        batchQueue.removeAll()
    }
}

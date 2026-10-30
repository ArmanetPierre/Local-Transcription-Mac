import Foundation
import SpeakerKit
import WhisperKit

/// Evenements du moteur, equivalents aux messages JSON Lines de transcribe_bridge.py
public enum EngineEvent: Sendable {
    case initialize(audioDurationSec: Double, language: String?)
    case stepStart(step: String, number: Int, total: Int)
    case progress(step: String, percent: Double)
    case stepComplete(step: String, durationSec: Double, extra: [String: String])
    case log(level: String, message: String)
    case result(EngineResult)
}

public struct EngineResult: Sendable {
    public var segments: [TranscriptSegment]
    public var language: String
    public var totalDurationSec: Double
    public var speakerEmbeddings: [String: [Double]]
    public var speakerMatches: [String: String]
    public var speakerMatchScores: [String: Double]
}

public struct EngineOptions: Sendable {
    public var language: String?
    public var diarize = true
    public var numberOfSpeakers: Int?
    /// Seuil de regroupement des intervenants (SpeakerKit). nil = valeur par defaut.
    public var clusterDistanceThreshold: Float?
    public var embeddingsFile: String?
    public var recognitionThreshold = VoiceMatcher.defaultThreshold
    /// Diarisation en parallele de la transcription. Desactive par defaut : la
    /// diarisation native ne prend que quelques secondes, et en parallele les deux
    /// modeles se disputent la puce (mesure sur le banc).
    public var parallel = false

    public init() {}
}

/// Etape de la preparation des modeles (premier lancement), pour l'interface.
public struct PreparationProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Telechargement du modele de transcription (octets connus)
        case downloading
        /// Petits modeles d'identification des intervenants
        case downloadingSpeakerModels
        /// Core ML specialise les modeles pour la puce (hors ligne, quelques minutes)
        case optimizing
        /// Chargement en memoire (rapide)
        case loading
    }

    public var phase: Phase
    public var bytesDownloaded: Int64 = 0
    /// 0 si inconnu
    public var bytesTotal: Int64 = 0

    public init(phase: Phase, bytesDownloaded: Int64 = 0, bytesTotal: Int64 = 0) {
        self.phase = phase
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    /// Avancement du telechargement (0...1), nil si inconnu
    public var downloadFraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1, Double(bytesDownloaded) / Double(bytesTotal))
    }
}

/// Transcription + diarisation natives (WhisperKit + SpeakerKit, Core ML).
public final class NativeEngine {
    public static let whisperModel = "large-v3-v20240930_turbo"
    /// Variante compressee (645 Mo au lieu de 1,64 Go), utilisee par l'edition App Store.
    /// Banc 64 min : WER 18,9 % (contre 18,6 %), erreur d'intervenant 3,6 % (3,5 %),
    /// transcription un peu plus rapide (RTF 0,063 contre 0,072).
    public static let compactWhisperModel = "large-v3-v20240930_turbo_632MB"
    static let whisperRepo = "argmaxinc/whisperkit-coreml"
    /// Fichier ecrit dans le dossier du modele une fois le telechargement complet
    static let completeMarker = ".voxa-download-complete"

    /// Dossier des modeles. Il doit rester stable : Core ML prepare les modeles
    /// pour la puce au premier chargement (plusieurs minutes), par emplacement.
    public let modelsDirectory: URL
    /// Variante WhisperKit utilisee (par defaut `whisperModel`)
    public let whisperVariant: String
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?

    public init(modelsDirectory: URL, whisperVariant: String = NativeEngine.whisperModel) {
        self.modelsDirectory = modelsDirectory
        self.whisperVariant = whisperVariant
    }

    /// Racine du depot WhisperKit dans le cache local (meme disposition que HubApi)
    var whisperRepoFolder: URL {
        modelsDirectory.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.whisperRepo, isDirectory: true)
    }

    /// Dossier local du modele de transcription
    public var whisperModelFolder: URL {
        whisperRepoFolder.appendingPathComponent("openai_whisper-\(whisperVariant)", isDirectory: true)
    }

    /// Le modele de transcription est-il entierement telecharge ? (sans reseau)
    public var isWhisperModelDownloaded: Bool {
        Self.isCompleteModelFolder(whisperModelFolder, metadataFolder: metadataFolder(for: whisperModelFolder))
    }

    private func metadataFolder(for modelFolder: URL) -> URL {
        whisperRepoFolder.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(modelFolder.lastPathComponent, isDirectory: true)
    }

    /// Complet = marqueur ecrit par Voxa, ou (dossiers telecharges par une version
    /// precedente) les trois modeles presents sans fichier .incomplete en attente.
    static func isCompleteModelFolder(_ folder: URL, metadataFolder: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(completeMarker).path) { return true }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let weights = folder.appendingPathComponent("\(name).mlmodelc/coremldata.bin")
            if !fm.fileExists(atPath: weights.path) { return false }
        }
        if let enumerator = fm.enumerator(at: metadataFolder, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "incomplete" {
                return false
            }
        }
        return true
    }

    /// Telecharge et prepare les modeles (long la premiere fois).
    /// prewarm : specialise les modeles pour la puce (a faire une fois, a la preparation).
    /// Le telechargement reprend la ou il s'etait arrete (fichiers .incomplete).
    public func prepare(
        prewarm: Bool = true,
        progress: @escaping @Sendable (PreparationProgress) -> Void = { _ in },
        log: (String) -> Void = { _ in }
    ) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        var folder: URL?
        if whisperKit == nil {
            folder = try await downloadWhisperModelIfNeeded(progress: progress, log: log)
        }
        if speakerKit == nil {
            log("Loading SpeakerKit")
            progress(PreparationProgress(phase: .downloadingSpeakerModels))
            speakerKit = try await SpeakerKit(PyannoteConfig(
                downloadBase: modelsDirectory.path,
                download: true,
                load: true,
                verbose: false,
                logLevel: .error
            ))
        }
        if whisperKit == nil, let folder {
            log("Loading WhisperKit (\(whisperVariant), prewarm: \(prewarm))")
            progress(PreparationProgress(phase: prewarm ? .optimizing : .loading))
            whisperKit = try await WhisperKit(WhisperKitConfig(
                model: whisperVariant,
                downloadBase: modelsDirectory,
                modelFolder: folder.path,
                tokenizerFolder: modelsDirectory,
                verbose: false,
                logLevel: .error,
                prewarm: prewarm,
                load: true,
                download: false
            ))
        }
    }

    /// Telecharge le modele de transcription s'il manque (progression en octets)
    /// ainsi que son tokenizer. Rend le dossier local du modele.
    private func downloadWhisperModelIfNeeded(
        progress: @escaping @Sendable (PreparationProgress) -> Void,
        log: (String) -> Void
    ) async throws -> URL {
        let folder = whisperModelFolder
        if isWhisperModelDownloaded {
            log("WhisperKit model already downloaded: \(folder.lastPathComponent)")
        } else {
            log("Downloading WhisperKit model \(whisperVariant)")
            let total = (try? await Self.remoteSize(repo: Self.whisperRepo, path: folder.lastPathComponent)) ?? 0
            let metadata = metadataFolder(for: folder)
            progress(PreparationProgress(phase: .downloading, bytesDownloaded: Self.bytesOnDisk([folder, metadata]), bytesTotal: total))
            // Octets reellement ecrits sur le disque (fichiers finis + .incomplete) : la
            // progression de HubApi compte les fichiers, pas leur taille.
            let monitor = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    progress(PreparationProgress(phase: .downloading, bytesDownloaded: Self.bytesOnDisk([folder, metadata]), bytesTotal: total))
                }
            }
            defer { monitor.cancel() }
            let downloaded = try await WhisperKit.download(
                variant: whisperVariant,
                downloadBase: modelsDirectory,
                from: Self.whisperRepo
            )
            try Task.checkCancellation()
            guard downloaded.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path else {
                throw NativeEngineError.unexpectedModelFolder(downloaded.path)
            }
            monitor.cancel()
            progress(PreparationProgress(phase: .downloading, bytesDownloaded: max(total, Self.bytesOnDisk([folder])), bytesTotal: total))
        }
        // Tokenizer (quelques Mo) : telecharge maintenant, pour que toute la partie
        // reseau soit finie avant l'optimisation (longue, hors ligne)
        _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: modelsDirectory)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.completeMarker).path, contents: Data())
        return folder
    }

    /// Supprime les autres variantes du modele de transcription (apres un changement de
    /// modele), une fois la nouvelle prete. Rend les dossiers supprimes.
    @discardableResult
    public func removeOtherWhisperVariants() -> [URL] {
        let fm = FileManager.default
        let keep = whisperModelFolder.lastPathComponent
        let metadataRoot = whisperRepoFolder.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        var removed: [URL] = []
        for root in [whisperRepoFolder, metadataRoot] {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.lastPathComponent.hasPrefix("openai_whisper-") && entry.lastPathComponent != keep {
                if (try? fm.removeItem(at: entry)) != nil { removed.append(entry) }
            }
        }
        return removed
    }

    /// Erreur de reseau (pas de connexion, delai depasse...) : le telechargement
    /// pourra reprendre plus tard, la ou il s'etait arrete.
    public static func isNetworkError(_ error: Error) -> Bool {
        var current: Error? = error
        var depth = 0
        while let error = current, depth < 5 {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        // Erreurs de HubApi/WhisperKit qui n'exposent l'erreur reseau que dans leur texte
        let text = String(describing: error).lowercased()
        return ["offline", "internet", "network", "timed out", "not connected", "nsurlerrordomain", "connection"]
            .contains { text.contains($0) }
    }

    /// Taille totale des fichiers d'un dossier du depot (API Hugging Face)
    static func remoteSize(repo: String, path: String) async throws -> Int64 {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(path)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseTreeSize(data)
    }

    /// Somme des tailles d'une reponse /tree (taille LFS si presente)
    static func parseTreeSize(_ data: Data) throws -> Int64 {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return entries.reduce(Int64(0)) { sum, entry in
            guard entry["type"] as? String == "file" else { return sum }
            let lfs = (entry["lfs"] as? [String: Any])?["size"] as? NSNumber
            let size = lfs ?? (entry["size"] as? NSNumber)
            return sum + (size?.int64Value ?? 0)
        }
    }

    /// Octets presents sur le disque sous ces dossiers (hors fichiers .metadata)
    static func bytesOnDisk(_ folders: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for folder in folders {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension != "metadata" {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    public func transcribe(
        audioPath: String,
        options: EngineOptions,
        emit: @escaping @Sendable (EngineEvent) -> Void
    ) async throws {
        let t0 = Date()
        try await prepare(prewarm: false, log: { emit(.log(level: "info", message: $0)) })
        guard let whisperKit, let speakerKit else { return }

        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        let duration = Double(audio.count) / Double(WhisperKit.sampleRate)
        emit(.initialize(audioDurationSec: duration, language: options.language))
        let totalSteps = options.diarize ? 3 : 1

        // La diarisation tourne en parallele de la transcription. Sa progression
        // n'est annoncee qu'une fois la transcription finie (l'app suit une etape a la fois).
        let gate = ProgressGate()
        let runDiarization: @Sendable () async throws -> (DiarizationResult, TimeInterval) = {
            let start = Date()
            let result = try await speakerKit.diarize(
                audioArray: audio,
                options: PyannoteDiarizationOptions(
                    numberOfSpeakers: options.numberOfSpeakers,
                    clusterDistanceThreshold: options.clusterDistanceThreshold
                ),
                progressCallback: { progress in
                    if gate.isOpen {
                        emit(.progress(step: "diarization", percent: progress.fractionCompleted * 100))
                    }
                }
            )
            return (result, Date().timeIntervalSince(start))
        }
        let diarizationTask: Task<(DiarizationResult, TimeInterval), Error>? =
            options.diarize && options.parallel ? Task { try await runDiarization() } : nil

        // 1. Transcription
        emit(.stepStart(step: "transcription", number: 1, total: totalSteps))
        let t1 = Date()
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                emit(.progress(step: "transcription", percent: whisperKit.progress.fractionCompleted * 100))
            }
        }
        // Langue : imposee, sinon detectee sur plusieurs passages de l'enregistrement
        var language = options.language
        if language == nil {
            language = try await Self.detectLanguage(whisperKit, audio: audio)
            emit(.log(level: "info", message: "Langue detectee: \(language ?? "?")"))
        }

        // Memes reglages que whisperkit-cli. En particulier, pas de seuil sur la
        // confiance du premier mot (defaut -1.5 de l'API) : il fait sauter des
        // fenetres entieres de parole conversationnelle, jugees "silencieuses".
        var decoding = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            wordTimestamps: true,
            firstTokenLogProbThreshold: nil,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
        // Pas d'amorce (promptTokens) : elle ameliorait un peu la ponctuation, mais
        // decalait les horodatages des mots de plusieurs secondes, et donc
        // l'attribution aux intervenants (banc 64 min : erreurs d'intervenant
        // 5,4 % -> 3,5 %, WER 20,2 % -> 18,6 %, mots perdus 12 % -> 8,5 %).
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decoding)
        } catch {
            progressTask.cancel()
            diarizationTask?.cancel()
            throw error
        }
        progressTask.cancel()
        let merged = TranscriptionUtilities.mergeTranscriptionResults(results)
        if ProcessInfo.processInfo.environment["VOXA_DEBUG_WORDS"] != nil {
            for segment in merged.segments.prefix(3) {
                FileHandle.standardError.write(Data("SEG \(segment.text.debugDescription)\n".utf8))
                for word in (segment.words ?? []).prefix(25) {
                    FileHandle.standardError.write(Data("  W \(word.word.debugDescription)\n".utf8))
                }
            }
        }
        var segments = merged.segments.map { segment in
            TranscriptSegment(
                start: Double(segment.start),
                end: Double(segment.end),
                text: Self.cleanText(segment.text),
                words: (segment.words ?? []).map {
                    Word(text: Self.cleanText($0.word, keepLeadingSpace: true), start: Double($0.start), end: Double($0.end))
                }
            )
        }
        segments = PostProcessing.removeHallucinationLoops(segments)
            .filter { $0.end > $0.start && $0.text.trimmingCharacters(in: .whitespaces).count > 1 }
        emit(.stepComplete(step: "transcription", durationSec: Date().timeIntervalSince(t1),
                           extra: ["detected_language": merged.language, "segments_count": "\(segments.count)"]))

        var embeddings: [String: [Double]] = [:]
        var matches: [String: String] = [:]
        var matchScores: [String: Double] = [:]

        if options.diarize {
            // 2. Diarisation (deja bien avancee, voire finie, si lancee en parallele)
            emit(.stepStart(step: "diarization", number: 2, total: totalSteps))
            gate.open()
            let (diarization, diarizationTime): (DiarizationResult, TimeInterval)
            if let diarizationTask {
                (diarization, diarizationTime) = try await diarizationTask.value
            } else {
                (diarization, diarizationTime) = try await runDiarization()
            }
            var turns: [SpeakerTurn] = diarization.segments.compactMap { segment in
                guard let id = segment.speaker.speakerId else { return nil }
                return SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: Self.label(id))
            }
            for (id, centroid) in diarization.speakerCentroidEmbeddings {
                embeddings[Self.label(id)] = centroid.map(Double.init)
            }
            let gallery = VoiceMatcher.loadGallery(at: options.embeddingsFile)
            if !gallery.isEmpty, !embeddings.isEmpty {
                (matches, matchScores) = VoiceMatcher.match(embeddings, gallery: gallery, threshold: options.recognitionThreshold)
            }
            // Intervenants parasites : leurs mots reviennent aux voisins
            let spurious = PostProcessing.spuriousSpeakers(
                turns, audioDuration: duration, embeddings: embeddings, keep: Set(matches.keys)
            )
            if !spurious.isEmpty {
                emit(.log(level: "info", message: "Intervenants parasites retires: \(spurious.sorted())"))
                turns.removeAll { spurious.contains($0.speaker) }
                for label in spurious { embeddings.removeValue(forKey: label) }
            }
            if !matches.isEmpty {
                for (label, name) in matches {
                    emit(.log(level: "info", message: "Speaker match: \(label) -> \(name) (similarite: \(matchScores[label] ?? 0))"))
                }
            }
            emit(.stepComplete(step: "diarization", durationSec: diarizationTime,
                               extra: ["speakers": "\(Set(turns.map(\.speaker)).count)"]))

            // 3. Attribution mot par mot
            emit(.stepStart(step: "speaker_assignment", number: 3, total: totalSteps))
            // Diagnostic : VOXA_DEBUG_DUMP=fichier.json ecrit les tours et les mots horodates
            if let dump = ProcessInfo.processInfo.environment["VOXA_DEBUG_DUMP"] {
                Self.writeDebugDump(to: dump, segments: segments, turns: turns)
            }
            segments = PostProcessing.splitBySpeaker(segments, turns: turns)
        }

        emit(.result(EngineResult(
            segments: segments,
            language: merged.language,
            totalDurationSec: Date().timeIntervalSince(t0),
            speakerEmbeddings: embeddings,
            speakerMatches: matches,
            speakerMatchScores: matchScores
        )))
    }

    /// Langue dominante : probabilites cumulees sur 3 passages de 30 s (debut,
    /// milieu, fin), pour ne pas se fier au seul debut d'une reunion.
    static func detectLanguage(_ whisperKit: WhisperKit, audio: [Float]) async throws -> String? {
        let window = 30 * WhisperKit.sampleRate
        let starts: [Int] = audio.count <= window
            ? [0]
            : [0, audio.count / 2 - window / 2, max(0, audio.count - window - WhisperKit.sampleRate * 5)]
        var totals: [String: Float] = [:]
        for start in starts {
            let slice = Array(audio[start..<min(start + window, audio.count)])
            let (_, probabilities) = try await whisperKit.detectLangauge(audioArray: slice)
            for (code, probability) in probabilities { totals[code, default: 0] += probability }
        }
        return totals.max { $0.value < $1.value }?.key
    }

    static func label(_ id: Int) -> String {
        String(format: "SPEAKER_%02d", id)
    }

    /// Retire les jetons speciaux eventuels ("<|fr|>", "<|0.00|>"...)
    static func cleanText(_ text: String, keepLeadingSpace: Bool = false) -> String {
        let cleaned = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        return keepLeadingSpace ? cleaned : cleaned.trimmingCharacters(in: .whitespaces)
    }
}

public enum NativeEngineError: LocalizedError {
    case unexpectedModelFolder(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedModelFolder(let path): "Unexpected model folder: \(path)"
        }
    }
}

/// Laisse passer la progression de la diarisation seulement quand l'app suit cette etape
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

}

extension NativeEngine {
    /// Donnees brutes de l'attribution (tours de diarisation, mots horodates), pour les tests.
    static func writeDebugDump(to path: String, segments: [TranscriptSegment], turns: [SpeakerTurn]) {
        let json: [String: Any] = [
            "turns": turns.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker] },
            "segments": segments.map { segment in
                ["start": segment.start, "end": segment.end, "text": segment.text,
                 "words": segment.words.map { ["text": $0.text, "start": $0.start, "end": $0.end] }]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

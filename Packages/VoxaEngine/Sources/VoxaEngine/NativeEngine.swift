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

/// Transcription + diarisation natives (WhisperKit + SpeakerKit, Core ML).
public final class NativeEngine {
    public static let whisperModel = "large-v3-v20240930_turbo"

    /// Dossier des modeles. Il doit rester stable : Core ML prepare les modeles
    /// pour la puce au premier chargement (plusieurs minutes), par emplacement.
    public let modelsDirectory: URL
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Telecharge et prepare les modeles (long la premiere fois).
    /// prewarm : specialise les modeles pour la puce (a faire une fois, a la preparation).
    public func prepare(prewarm: Bool = true, log: (String) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        if whisperKit == nil {
            log("Chargement de WhisperKit (\(Self.whisperModel))...")
            whisperKit = try await WhisperKit(WhisperKitConfig(
                model: Self.whisperModel,
                downloadBase: modelsDirectory,
                verbose: false,
                logLevel: .error,
                prewarm: prewarm,
                load: true,
                download: true
            ))
        }
        if speakerKit == nil {
            log("Chargement de SpeakerKit...")
            speakerKit = try await SpeakerKit(PyannoteConfig(
                downloadBase: modelsDirectory.path,
                download: true,
                load: true,
                verbose: false,
                logLevel: .error
            ))
        }
    }

    public func transcribe(
        audioPath: String,
        options: EngineOptions,
        emit: @escaping @Sendable (EngineEvent) -> Void
    ) async throws {
        let t0 = Date()
        try await prepare(prewarm: false) { emit(.log(level: "info", message: $0)) }
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
        // Memes reglages que whisperkit-cli. En particulier, pas de seuil sur la
        // confiance du premier mot (defaut -1.5 de l'API) : il fait sauter des
        // fenetres entieres de parole conversationnelle, jugees "silencieuses".
        let decoding = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: options.language,
            usePrefillPrompt: options.language != nil,
            wordTimestamps: true,
            firstTokenLogProbThreshold: nil,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
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

    static func label(_ id: Int) -> String {
        String(format: "SPEAKER_%02d", id)
    }

    /// Retire les jetons speciaux eventuels ("<|fr|>", "<|0.00|>"...)
    static func cleanText(_ text: String, keepLeadingSpace: Bool = false) -> String {
        let cleaned = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        return keepLeadingSpace ? cleaned : cleaned.trimmingCharacters(in: .whitespaces)
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

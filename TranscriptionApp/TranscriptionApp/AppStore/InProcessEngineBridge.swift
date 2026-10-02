import Foundation
import VoxaEngine

/// Version App Store : remplace PythonBridge. Meme interface et memes messages
/// (PythonMessage), mais le moteur natif tourne dans le processus de l'app.
typealias PythonBridge = InProcessEngineBridge

/// Un seul moteur dans la version App Store
enum TranscriptionEngine: String {
    case native
    static var selected: TranscriptionEngine { .native }
}

enum EngineBridgeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

@Observable
final class InProcessEngineBridge {
    var isRunning = false
    var currentStep = ""
    var progressPercent: Double = 0

    // Pas de Python dans cette version : gardes pour la compatibilite d'interface
    static let defaultPythonPath = ""
    static let defaultScriptPath = ""

    private var task: Task<Void, Never>?

    func transcribe(
        audioPath: String,
        model: WhisperModel = .largeV3Turbo,
        language: String? = nil,
        numSpeakers: Int? = nil,
        minSpeakers: Int? = nil,
        maxSpeakers: Int? = nil,
        diarize: Bool = true,
        hfToken: String,
        pythonPath: String = "",
        scriptPath: String = "",
        engine: TranscriptionEngine = .native
    ) -> AsyncThrowingStream<PythonMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                self.isRunning = true
                defer { self.isRunning = false }
                do {
                    // Premiere utilisation ou mise a jour : preparation des modeles
                    if !NativeModels.shared.isPrepared {
                        continuation.yield(.log(LogMessage(level: "info", message: "Preparation des modeles")))
                        continuation.yield(.stepStart(StepStartMessage(step: "preparing_models", stepNumber: 0, totalSteps: 3)))
                        try await NativeModels.shared.prepare()
                    }
                    var options = EngineOptions()
                    options.language = language
                    options.diarize = diarize
                    options.numberOfSpeakers = numSpeakers
                    options.embeddingsFile = SpeakerEmbeddingStore.embeddingsFilePath
                    try await NativeModels.shared.engine.transcribe(audioPath: audioPath, options: options) { event in
                        continuation.yield(Self.message(for: event, model: model))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.error(ErrorMessage(step: nil, message: error.localizedDescription, fatal: true)))
                    continuation.finish(throwing: EngineBridgeError.failed(error.localizedDescription))
                }
            }
            self.task = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Evenement du moteur -> message du protocole de l'app
    static func message(for event: EngineEvent, model: WhisperModel) -> PythonMessage {
        switch event {
        case let .initialize(duration, language):
            return .initialize(InitMessage(audioFile: "", audioDurationSec: duration, model: NativeEngine.whisperModel,
                                           language: language, diarizationEnabled: true))
        case let .stepStart(step, number, total):
            return .stepStart(StepStartMessage(step: step, stepNumber: number, totalSteps: total))
        case let .progress(step, percent):
            let value = min(max(percent, 0), 100)
            return .progress(ProgressMessage(step: step, substep: nil, completed: Int(value), total: 100, percent: value))
        case let .stepComplete(step, duration, extra):
            return .stepComplete(StepCompleteMessage(
                step: step,
                durationSec: duration,
                segmentsCount: extra["segments_count"].flatMap(Int.init),
                detectedLanguage: extra["detected_language"],
                speakers: nil
            ))
        case let .log(level, message):
            return .log(LogMessage(level: level, message: message))
        case let .result(result):
            let segments = result.segments.enumerated().map { index, segment in
                ResultSegment(id: index, start: segment.start, end: segment.end, text: segment.text,
                              speaker: segment.speaker, avgLogprob: nil, noSpeechProb: nil)
            }
            return .result(ResultMessage(
                segments: segments,
                language: result.language,
                totalDurationSec: result.totalDurationSec,
                speakerEmbeddings: result.speakerEmbeddings.isEmpty ? nil : result.speakerEmbeddings,
                speakerMatches: result.speakerMatches.isEmpty ? nil : result.speakerMatches,
                speakerMatchScores: result.speakerMatchScores.isEmpty ? nil : result.speakerMatchScores
            ))
        }
    }
}

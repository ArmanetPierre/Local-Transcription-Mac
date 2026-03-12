import Foundation

// MARK: - Python JSON Lines Protocol

enum PythonMessage: Decodable {
    case initialize(InitMessage)
    case stepStart(StepStartMessage)
    case progress(ProgressMessage)
    case stepComplete(StepCompleteMessage)
    case result(ResultMessage)
    case error(ErrorMessage)
    case log(LogMessage)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "init":
            self = .initialize(try InitMessage(from: decoder))
        case "step_start":
            self = .stepStart(try StepStartMessage(from: decoder))
        case "progress":
            self = .progress(try ProgressMessage(from: decoder))
        case "step_complete":
            self = .stepComplete(try StepCompleteMessage(from: decoder))
        case "result":
            self = .result(try ResultMessage(from: decoder))
        case "error":
            self = .error(try ErrorMessage(from: decoder))
        case "log":
            self = .log(try LogMessage(from: decoder))
        default:
            self = .log(LogMessage(level: "debug", message: "Unknown type: \(type)"))
        }
    }
}

struct InitMessage: Decodable {
    let audioFile: String
    let audioDurationSec: Double
    let model: String
    let language: String?
    let diarizationEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case audioFile = "audio_file"
        case audioDurationSec = "audio_duration_sec"
        case model, language
        case diarizationEnabled = "diarization_enabled"
    }
}

struct StepStartMessage: Decodable {
    let step: String
    let stepNumber: Int
    let totalSteps: Int

    enum CodingKeys: String, CodingKey {
        case step
        case stepNumber = "step_number"
        case totalSteps = "total_steps"
    }
}

struct ProgressMessage: Decodable {
    let step: String
    let substep: String?
    let completed: Int
    let total: Int
    let percent: Double
}

struct StepCompleteMessage: Decodable {
    let step: String
    let durationSec: Double
    let segmentsCount: Int?
    let detectedLanguage: String?
    let speakers: [String]?

    enum CodingKeys: String, CodingKey {
        case step, speakers
        case durationSec = "duration_sec"
        case segmentsCount = "segments_count"
        case detectedLanguage = "detected_language"
    }
}

struct ResultSegment: Codable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
    let avgLogprob: Double?
    let noSpeechProb: Double?

    enum CodingKeys: String, CodingKey {
        case id, start, end, text, speaker
        case avgLogprob = "avg_logprob"
        case noSpeechProb = "no_speech_prob"
    }

    init(id: Int, start: Double, end: Double, text: String, speaker: String?, avgLogprob: Double?, noSpeechProb: Double?) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
    }
}

struct ResultMessage: Decodable {
    let segments: [ResultSegment]
    let language: String
    let totalDurationSec: Double
    let speakerEmbeddings: [String: [Double]]?
    let speakerMatches: [String: String]?

    enum CodingKeys: String, CodingKey {
        case segments, language
        case totalDurationSec = "total_duration_sec"
        case speakerEmbeddings = "speaker_embeddings"
        case speakerMatches = "speaker_matches"
    }
}

struct ErrorMessage: Decodable {
    let step: String?
    let message: String
    let fatal: Bool
}

struct LogMessage: Decodable {
    let level: String
    let message: String
}

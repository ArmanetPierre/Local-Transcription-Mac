import Foundation
import SwiftData

@Model
final class TranscriptionProject {
    var id: UUID = UUID()
    var title: String = ""
    var audioFilePath: String = ""
    var audioFileName: String = ""
    var audioDurationSec: Double = 0
    var statusRaw: String = TranscriptionStatus.pending.rawValue
    var whisperModel: String = WhisperModel.largeV3Turbo.rawValue
    var language: String?
    var diarizationEnabled: Bool = true
    var speakerNamesData: Data?
    /// Intervenants nommes automatiquement par reconnaissance vocale : {label: similarite}
    var autoRecognizedSpeakersData: Data?
    var createdAt: Date = Date()
    var completedAt: Date?
    var transcriptionDurationSec: Double?
    var diarizationDurationSec: Double?
    var totalProcessingDurationSec: Double?
    var errorMessage: String?
    var notes: String?
    var progressPercent: Double = 0
    var currentStep: String?
    var speakerSummariesData: Data?
    var summaryModelUsed: String?
    var meetingReportData: Data?
    var reportModelUsed: String?

    @Relationship(deleteRule: .cascade, inverse: \Segment.project)
    var segments: [Segment] = []

    init() {}

    var status: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var speakerNames: [String: String] {
        get {
            guard let data = speakerNamesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            speakerNamesData = try? JSONEncoder().encode(newValue)
        }
    }

    var sortedSegments: [Segment] {
        segments.sorted { $0.index < $1.index }
    }

    var uniqueSpeakers: [String] {
        Array(Set(segments.compactMap(\.speakerLabel))).sorted()
    }

    var autoRecognizedSpeakers: [String: Double] {
        get {
            guard let data = autoRecognizedSpeakersData else { return [:] }
            return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        }
        set {
            autoRecognizedSpeakersData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    var speakerSummaries: [String: String] {
        get {
            guard let data = speakerSummariesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            speakerSummariesData = try? JSONEncoder().encode(newValue)
        }
    }

    var meetingReport: String? {
        get {
            guard let data = meetingReportData else { return nil }
            return try? JSONDecoder().decode(String.self, from: data)
        }
        set {
            meetingReportData = try? JSONEncoder().encode(newValue)
        }
    }

    func displayName(for speakerLabel: String) -> String {
        speakerNames[speakerLabel] ?? speakerLabel
    }

    func sampleSegments(for speakerLabel: String, count: Int = 3) -> [Segment] {
        let speakerSegments = sortedSegments.filter { $0.speakerLabel == speakerLabel }
        guard speakerSegments.count > count else { return speakerSegments }
        let step = speakerSegments.count / count
        return (0..<count).map { speakerSegments[$0 * step] }
    }

    var formattedDuration: String {
        let minutes = Int(audioDurationSec / 60)
        if minutes < 1 { return "< 1 min" }
        return "\(minutes) min"
    }

    static func create(audioURL: URL) -> TranscriptionProject {
        let project = TranscriptionProject()
        project.audioFilePath = audioURL.path
        project.audioFileName = audioURL.lastPathComponent
        project.title = audioURL.deletingPathExtension().lastPathComponent
        return project
    }
}

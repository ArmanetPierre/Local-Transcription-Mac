import Foundation

enum TranscriptionStatus: String, Codable, CaseIterable {
    case pending
    case transcribing
    case diarizing
    case merging
    case awaitingSpeakerNames
    case generatingSummary
    case completed
    case failed

    var label: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .transcribing: String(localized: "Transcribing...")
        case .diarizing: String(localized: "Diarizing...")
        case .merging: String(localized: "Assigning speakers...")
        case .awaitingSpeakerNames: String(localized: "Speaker identification")
        case .generatingSummary: String(localized: "Generating summary...")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Error")
        }
    }

    var isProcessing: Bool {
        switch self {
        case .transcribing, .diarizing, .merging, .generatingSummary: true
        default: false
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny
    case base
    case small
    case medium
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: String(localized: "Tiny (fast, low quality)")
        case .base: "Base"
        case .small: "Small"
        case .medium: "Medium"
        case .largeV3: String(localized: "Large v3 (best quality)")
        case .largeV3Turbo: String(localized: "Large v3 Turbo (recommended)")
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, json, srt, md

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: String(localized: "Text (.txt)")
        case .json: "JSON (.json)"
        case .srt: String(localized: "Subtitles (.srt)")
        case .md: "Markdown (.md)"
        }
    }

    var fileExtension: String { rawValue }
}

enum OllamaModel: String, CaseIterable, Identifiable {
    case llama3_1 = "llama3.1:8b"
    case mistral = "mistral:latest"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llama3_1: "Llama 3.1 (8B)"
        case .mistral: "Mistral"
        }
    }

    /// Taille approximative du telechargement
    var approximateSize: String {
        switch self {
        case .llama3_1: "4.9 GB"
        case .mistral: "4.1 GB"
        }
    }
}

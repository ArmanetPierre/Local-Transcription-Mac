import Foundation
import VoxaEngine

// voxa-engine : moteur natif de Voxa en ligne de commande.
// Memes arguments et meme protocole JSON Lines que transcribe_bridge.py.
//
//   voxa-engine --audio fichier.m4a --json-protocol [--language fr]
//               [--embeddings-file speaker_embeddings.json] [--num-speakers N]
//               [--models-dir DIR] [--cluster-threshold 0.7] [--no-diarize] [--parallel]
//   voxa-engine --prepare [--models-dir DIR]     (telecharge et prepare les modeles)

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func encode(_ event: EngineEvent) {
    switch event {
    case let .initialize(duration, language):
        var msg: [String: Any] = ["type": "init", "audio_file": "", "audio_duration_sec": duration,
                                  "model": NativeEngine.whisperModel, "diarization_enabled": true]
        if let language { msg["language"] = language }
        emit(msg)
    case let .stepStart(step, number, total):
        emit(["type": "step_start", "step": step, "step_number": number, "total_steps": total])
    case let .progress(step, percent):
        let value = (min(max(percent, 0), 100) * 10).rounded() / 10
        emit(["type": "progress", "step": step, "completed": Int(value), "total": 100, "percent": value])
    case let .stepComplete(step, duration, extra):
        var msg: [String: Any] = ["type": "step_complete", "step": step, "duration_sec": (duration * 10).rounded() / 10]
        if let language = extra["detected_language"] { msg["detected_language"] = language }
        if let count = extra["segments_count"].flatMap(Int.init) { msg["segments_count"] = count }
        emit(msg)
    case let .log(level, message):
        emit(["type": "log", "level": level, "message": message])
    case let .result(result):
        var msg: [String: Any] = [
            "type": "result",
            "language": result.language,
            "total_duration_sec": (result.totalDurationSec * 10).rounded() / 10,
            "segments": result.segments.enumerated().map { index, segment -> [String: Any] in
                var dict: [String: Any] = [
                    "id": index,
                    "start": (segment.start * 1000).rounded() / 1000,
                    "end": (segment.end * 1000).rounded() / 1000,
                    "text": segment.text,
                ]
                if let speaker = segment.speaker { dict["speaker"] = speaker }
                return dict
            },
        ]
        if !result.speakerEmbeddings.isEmpty { msg["speaker_embeddings"] = result.speakerEmbeddings }
        if !result.speakerMatches.isEmpty {
            msg["speaker_matches"] = result.speakerMatches
            msg["speaker_match_scores"] = result.speakerMatchScores
        }
        emit(msg)
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
func value(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let defaultModels = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Voxa/Models", isDirectory: true)
let modelsDir = value("--models-dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultModels
let engine = NativeEngine(modelsDirectory: modelsDir)

do {
    if arguments.contains("--prepare") {
        let start = Date()
        try await engine.prepare { emit(["type": "log", "level": "info", "message": $0]) }
        emit(["type": "log", "level": "info", "message": "Modeles prets en \(Int(Date().timeIntervalSince(start))) s"])
        exit(0)
    }
    guard let audio = value("--audio") else {
        FileHandle.standardError.write(Data("Usage: voxa-engine --audio FICHIER [--json-protocol] ...\n".utf8))
        exit(2)
    }
    var options = EngineOptions()
    options.language = value("--language")
    options.diarize = !arguments.contains("--no-diarize")
    options.numberOfSpeakers = value("--num-speakers").flatMap(Int.init)
    options.clusterDistanceThreshold = value("--cluster-threshold").flatMap(Float.init)
    options.embeddingsFile = value("--embeddings-file")
    options.parallel = arguments.contains("--parallel")
    try await engine.transcribe(audioPath: audio, options: options, emit: encode)
} catch {
    emit(["type": "error", "message": "\(error)", "fatal": true])
    exit(1)
}

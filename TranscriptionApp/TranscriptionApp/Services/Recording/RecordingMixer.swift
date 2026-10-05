import Accelerate
import AVFoundation
import Foundation

/// Mixe les pistes d'une session (systeme stereo + micro mono, deja alignees sur la
/// meme horloge) en un fichier final, puis verifie qu'il est lisible et complet.
enum RecordingMixer {
    enum MixError: LocalizedError {
        case noReadableTrack
        case incomplete(expected: TimeInterval, actual: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .noReadableTrack:
                "Aucune piste lisible"
            case let .incomplete(expected, actual):
                "Fichier final incomplet (\(Int(actual)) s sur \(Int(expected)) s)"
            }
        }
    }

    /// Mixe vers `outputURL` (.m4a AAC). Si l'encodage AAC echoue, produit un WAV
    /// a la place (meme nom, extension .wav). Retourne l'URL du fichier final verifie.
    static func mix(tracks: [URL], to outputURL: URL) throws -> URL {
        let readers = tracks.compactMap { url -> AVAudioFile? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try AVAudioFile(forReading: url)
            } catch {
                print("[Mixer] Piste illisible \(url.lastPathComponent): \(error)")
                return nil
            }
        }
        guard !readers.isEmpty else { throw MixError.noReadableTrack }

        let totalFrames = readers.map(\.length).max() ?? 0
        let expected = Double(totalFrames) / AlignedTrackWriter.sampleRate
        print("[Mixer] \(readers.count) piste(s), \(String(format: "%.1f", expected)) s")

        do {
            return try writeVerified(readers: readers, totalFrames: totalFrames, to: outputURL, aac: true, expected: expected)
        } catch {
            print("[Mixer] Export AAC en echec (\(error)), repli sur WAV")
            for reader in readers { reader.framePosition = 0 }
            let wavURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
            return try writeVerified(readers: readers, totalFrames: totalFrames, to: wavURL, aac: false, expected: expected)
        }
    }

    /// Duree attendue d'une session : la plus longue de ses pistes
    static func expectedDuration(of tracks: [URL]) -> TimeInterval {
        tracks.compactMap { try? AVAudioFile(forReading: $0) }
            .map { Double($0.length) / $0.fileFormat.sampleRate }
            .max() ?? 0
    }

    /// Ecrit sous un nom temporaire, verifie, puis renomme : un fichier final au bon nom
    /// est toujours complet (un mixage interrompu ne peut pas passer pour termine).
    private static func writeVerified(
        readers: [AVAudioFile], totalFrames: AVAudioFramePosition, to url: URL, aac: Bool, expected: TimeInterval
    ) throws -> URL {
        let fm = FileManager.default
        let partial = url.deletingPathExtension().appendingPathExtension("partial").appendingPathExtension(url.pathExtension)
        defer { try? fm.removeItem(at: partial) }
        try write(readers: readers, totalFrames: totalFrames, to: partial, aac: aac)
        try verify(partial, expected: expected)
        try? fm.removeItem(at: url)
        try fm.moveItem(at: partial, to: url)
        return url
    }

    private static func write(readers: [AVAudioFile], totalFrames: AVAudioFramePosition, to url: URL, aac: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        guard !readers.isEmpty else { throw MixError.noReadableTrack }
        let sampleRate = AlignedTrackWriter.sampleRate
        let settings: [String: Any] = aac
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            : [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        let output = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let outFormat = output.processingFormat
        let chunk: AVAudioFrameCount = 48000 * 5
        guard let mixBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
            throw MixError.noReadableTrack
        }
        let readBuffers = readers.map {
            AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk)
        }
        // Une piste abimee (fin d'un fichier coupe par un plantage) est ecartee
        // a partir de l'erreur, sans faire echouer l'autre piste
        var broken = Set<Int>()

        var position: AVAudioFramePosition = 0
        while position < totalFrames {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), totalFrames - position))
            mixBuffer.frameLength = n
            guard let out = mixBuffer.floatChannelData else { break }
            for ch in 0..<2 { out[ch].update(repeating: 0, count: Int(n)) }

            for (index, (reader, buffer)) in zip(readers, readBuffers).enumerated() {
                guard let buffer, !broken.contains(index), reader.framePosition < reader.length else { continue }
                buffer.frameLength = 0
                do {
                    try reader.read(into: buffer, frameCount: n)
                } catch {
                    print("[Mixer] Lecture impossible de \(reader.url.lastPathComponent) a \(reader.framePosition): \(error), piste arretee ici")
                    broken.insert(index)
                    continue
                }
                guard let src = buffer.floatChannelData else { continue }
                let channels = Int(buffer.format.channelCount)
                for ch in 0..<2 {
                    let to = out[ch]
                    vDSP_vadd(to, 1, src[min(ch, channels - 1)], 1, to, 1, vDSP_Length(buffer.frameLength))
                }
            }
            // Somme des pistes : on evite l'ecretage
            var low: Float = -1, high: Float = 1
            for ch in 0..<2 {
                vDSP_vclip(out[ch], 1, &low, &high, out[ch], 1, vDSP_Length(n))
            }
            try output.write(from: mixBuffer)
            position += AVAudioFramePosition(n)
        }
        if #available(macOS 15.0, *) { output.close() }
    }

    /// Le fichier doit se relire et durer au moins 98 % de la duree attendue.
    static func verify(_ url: URL, expected: TimeInterval) throws {
        let file = try AVAudioFile(forReading: url)
        let actual = Double(file.length) / file.fileFormat.sampleRate
        guard actual >= expected * 0.98 - 1 else {
            throw MixError.incomplete(expected: expected, actual: actual)
        }
        print("[Mixer] Fichier final verifie: \(url.lastPathComponent), \(String(format: "%.1f", actual)) s")
    }
}

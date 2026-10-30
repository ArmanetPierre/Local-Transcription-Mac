import AVFoundation
import CoreMedia
import Foundation

/// Piste PCM (CAF) ecrite au fil de l'eau et alignee sur l'horloge de la session.
///
/// - CAF : la taille du bloc audio reste "jusqu'a la fin du fichier" tant que le fichier
///   n'est pas ferme, donc une piste reste lisible apres un plantage ou un arret brutal.
/// - PCM : pas d'encodeur qui peut echouer en cours de route (contrairement a AAC).
/// - Chaque tampon est place a sa position reelle (horloge hote) : si une source
///   s'interrompt (redemarrage du micro, de la capture systeme), le trou est comble
///   par du silence et les deux pistes restent synchronisees.
///
/// Thread-safe : la capture systeme et le micro ecrivent depuis leurs propres files.
final class AlignedTrackWriter: @unchecked Sendable {
    static let sampleRate: Double = 48000
    /// Au-dela, on ne comble pas (horloge aberrante) : on enchaine simplement
    static let maxGapFill: TimeInterval = 600
    /// Tolerance avant de combler ou de rogner (gigue normale des tampons)
    static let tolerance: TimeInterval = 0.04

    let url: URL
    let format: AVAudioFormat
    private var file: AVAudioFile?
    private let lock = NSLock()
    private let sessionStart: TimeInterval
    private var clockOffset: TimeInterval?
    private var converters: [String: AVAudioConverter] = [:]

    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Dernier tampon recu de la source (meme s'il n'a pas pu etre ecrit) : sert a
    /// detecter une source muette, sans confondre avec une erreur d'ecriture
    private var _lastCallbackHostTime: TimeInterval?
    var lastCallbackHostTime: TimeInterval? { lock.withLock { _lastCallbackHostTime } }
    private(set) var writeErrors = 0

    /// - Parameter sessionStart: debut de la session, en secondes d'horloge hote
    init(url: URL, channels: AVAudioChannelCount, sessionStart: TimeInterval) throws {
        self.url = url
        self.sessionStart = sessionStart
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.file = file
        self.format = file.processingFormat
    }

    var duration: TimeInterval {
        lock.withLock { Double(framesWritten) / Self.sampleRate }
    }

    /// Ecrit un tampon capture a `bufferTime` (secondes, horloge de la source).
    /// `arrivalHostTime` (maintenant, horloge hote) sert a recaler une source dont
    /// l'horloge n'est pas l'horloge hote.
    func write(_ buffer: AVAudioPCMBuffer, bufferTime: TimeInterval, arrivalHostTime: TimeInterval) {
        lock.withLock {
            _lastCallbackHostTime = arrivalHostTime
            guard let file, buffer.frameLength > 0 else { return }
            guard let converted = convert(buffer) else { return }

            // Meme horloge que la session si l'ecart est plausible, sinon on recale
            if clockOffset == nil {
                clockOffset = abs(arrivalHostTime - bufferTime) < 5 ? 0 : arrivalHostTime - bufferTime
                if clockOffset != 0 {
                    print("[Track \(url.lastPathComponent)] Horloge source recalee de \(clockOffset!)s")
                }
            }
            let hostTime = bufferTime + (clockOffset ?? 0)
            let expected = AVAudioFramePosition(((hostTime - sessionStart) * Self.sampleRate).rounded())
            var gap = expected - framesWritten
            let tolerance = AVAudioFramePosition(Self.tolerance * Self.sampleRate)

            var toWrite = converted
            if gap > tolerance {
                if gap <= AVAudioFramePosition(Self.maxGapFill * Self.sampleRate) {
                    if gap > AVAudioFramePosition(Self.sampleRate) {
                        print("[Track \(url.lastPathComponent)] Trou de \(String(format: "%.1f", Double(gap) / Self.sampleRate))s comble par du silence")
                    }
                    writeSilence(frames: gap, to: file)
                } else {
                    // Horloge qui a saute : on recale la source sur la fin de la piste,
                    // sinon tous les tampons suivants retomberaient ici
                    print("[Track \(url.lastPathComponent)] Ecart aberrant (\(gap) trames) : horloge recalee")
                    clockOffset = (clockOffset ?? 0) - Double(gap) / Self.sampleRate
                }
            } else if gap < -tolerance {
                // Chevauchement (tampon plus ancien que la fin de la piste) : on rogne le debut
                gap = -gap
                guard gap < AVAudioFramePosition(toWrite.frameLength) else { return }
                toWrite = Self.dropFirst(gap, of: toWrite)
            }

            do {
                try file.write(from: toWrite)
                framesWritten += AVAudioFramePosition(toWrite.frameLength)
            } catch {
                writeErrors += 1
                if writeErrors <= 5 {
                    print("[Track \(url.lastPathComponent)] Erreur d'ecriture: \(error)")
                }
            }
        }
    }

    /// Complete la piste en silence jusqu'a `frames` (fin commune des deux pistes).
    func pad(toFrames frames: AVAudioFramePosition) {
        lock.withLock {
            guard let file, frames > framesWritten else { return }
            writeSilence(frames: frames - framesWritten, to: file)
        }
    }

    /// Ferme le fichier (ecrit la taille definitive du bloc audio).
    func close() {
        lock.withLock {
            if #available(macOS 15.0, *) {
                file?.close()
            }
            file = nil
        }
    }

    // MARK: - Private

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) {
        var remaining = frames
        let chunk: AVAudioFrameCount = 48000
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            silence.frameLength = n
            for ch in 0..<Int(format.channelCount) {
                silence.floatChannelData?[ch].update(repeating: 0, count: Int(n))
            }
            do {
                try file.write(from: silence)
            } catch {
                print("[Track \(url.lastPathComponent)] Erreur d'ecriture du silence: \(error)")
                return
            }
            framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
    }

    /// Convertit vers le format de la piste (48 kHz, float, nombre de canaux de la piste).
    /// Une source a plus de canaux (micro avec voice processing : jusqu'a 9 canaux
    /// identiques) est reduite a ses premiers canaux.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let src = buffer.format
        if src == format { return buffer }

        // Cas courant : meme frequence, float non entrelace → copie des premiers canaux
        if src.sampleRate == format.sampleRate, src.commonFormat == .pcmFormatFloat32,
           !src.isInterleaved, let srcData = buffer.floatChannelData,
           let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
           let outData = out.floatChannelData {
            out.frameLength = buffer.frameLength
            let srcChannels = Int(src.channelCount)
            for ch in 0..<Int(format.channelCount) {
                let from = srcData[min(ch, srcChannels - 1)]
                outData[ch].update(from: from, count: Int(buffer.frameLength))
            }
            return out
        }

        // Autre format (frequence differente, entier, entrelace) : AVAudioConverter
        let key = "\(src)"
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else {
            guard let created = AVAudioConverter(from: src, to: format) else {
                print("[Track \(url.lastPathComponent)] Conversion impossible depuis \(src)")
                return nil
            }
            if src.channelCount > format.channelCount {
                created.channelMap = (0..<Int(format.channelCount)).map { NSNumber(value: $0) }
            }
            converters[key] = created
            converter = created
            print("[Track \(url.lastPathComponent)] Conversion depuis \(src)")
        }
        let ratio = format.sampleRate / src.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            print("[Track \(url.lastPathComponent)] Erreur de conversion: \(String(describing: error))")
            return nil
        }
        return out
    }

    private static func dropFirst(_ frames: AVAudioFramePosition, of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - frames)
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return buffer }
        out.frameLength = remaining
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch] + Int(frames), count: Int(remaining))
        }
        return out
    }
}

extension AVAudioPCMBuffer {
    /// Copie le PCM d'un CMSampleBuffer (ScreenCaptureKit) dans un AVAudioPCMBuffer.
    static func from(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              case let frames = AVAudioFrameCount(sampleBuffer.numSamples), frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<Int(frames), into: buffer.mutableAudioBufferList)
        } catch {
            return nil
        }
        return buffer
    }
}

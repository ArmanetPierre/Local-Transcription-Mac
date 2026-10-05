import AVFoundation
import XCTest
@testable import Voxa

/// Enregistrement : pistes alignees, lisibles apres un arret brutal, mixage verifie.
final class RecordingRobustnessTests: XCTestCase {
    private var directory: URL!
    private let sr = AlignedTrackWriter.sampleRate

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxaRecTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Tampon de `seconds` secondes rempli avec `value`
    private func buffer(_ seconds: Double, value: Float, channels: AVAudioChannelCount, rate: Double = 48000) -> AVAudioPCMBuffer {
        // Plus de 2 canaux : AVAudioFormat exige une disposition explicite
        let format = channels <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            : AVAudioFormat(
                standardFormatWithSampleRate: rate,
                channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            )
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            buffer.floatChannelData![ch].update(repeating: value, count: Int(frames))
        }
        return buffer
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func testGapIsFilledWithSilenceToKeepAlignment() throws {
        let url = directory.appendingPathComponent("t.caf")
        let track = try AlignedTrackWriter(url: url, channels: 1, sessionStart: 100)
        track.write(buffer(1, value: 0.5, channels: 1), bufferTime: 100, arrivalHostTime: 100)
        // La source s'interrompt 2 s, puis reprend a t = 3 s
        track.write(buffer(1, value: 0.5, channels: 1), bufferTime: 103, arrivalHostTime: 103)
        track.close()

        let s = try samples(url)
        XCTAssertEqual(s.count, Int(4 * sr), "1 s + 2 s de silence + 1 s")
        XCTAssertEqual(s[Int(0.5 * sr)], 0.5, accuracy: 0.001)
        XCTAssertEqual(s[Int(2 * sr)], 0, "le trou est du silence")
        XCTAssertEqual(s[Int(3.5 * sr)], 0.5, accuracy: 0.001, "la reprise est a sa vraie place")
    }

    func testOverlappingBufferIsTrimmed() throws {
        let url = directory.appendingPathComponent("t.caf")
        let track = try AlignedTrackWriter(url: url, channels: 1, sessionStart: 0)
        track.write(buffer(2, value: 0.25, channels: 1), bufferTime: 0, arrivalHostTime: 0)
        // Tampon qui recommence 1 s trop tot : sa premiere seconde est deja ecrite
        track.write(buffer(2, value: 0.75, channels: 1), bufferTime: 1, arrivalHostTime: 1)
        track.close()

        let s = try samples(url)
        XCTAssertEqual(s.count, Int(3 * sr))
        XCTAssertEqual(s[Int(1.5 * sr)], 0.25, accuracy: 0.001)
        XCTAssertEqual(s[Int(2.5 * sr)], 0.75, accuracy: 0.001)
    }

    func testSourceOnAnotherClockIsAnchoredOnArrival() throws {
        let url = directory.appendingPathComponent("t.caf")
        let track = try AlignedTrackWriter(url: url, channels: 1, sessionStart: 1000)
        // Horloge source sans rapport (0 s) : premier tampon arrive a t = 1 s de session
        track.write(buffer(1, value: 0.5, channels: 1), bufferTime: 0, arrivalHostTime: 1001)
        track.write(buffer(1, value: 0.5, channels: 1), bufferTime: 1, arrivalHostTime: 1002.3)
        track.close()
        XCTAssertEqual(try samples(url).count, Int(3 * sr))
    }

    func testMultichannelAndResampledInputs() throws {
        let url = directory.appendingPathComponent("t.caf")
        let track = try AlignedTrackWriter(url: url, channels: 1, sessionStart: 0)
        // Micro avec voice processing : 9 canaux
        track.write(buffer(1, value: 0.5, channels: 9), bufferTime: 0, arrivalHostTime: 0)
        // Casque Bluetooth : 16 kHz
        track.write(buffer(1, value: 0.5, channels: 1, rate: 16000), bufferTime: 1, arrivalHostTime: 1)
        track.close()
        let s = try samples(url)
        XCTAssertEqual(Double(s.count), 2 * sr, accuracy: 200)
        XCTAssertEqual(s[Int(0.5 * sr)], 0.5, accuracy: 0.001)
    }

    /// Le fichier n'est jamais ferme (plantage) : il doit rester lisible
    func testUnclosedTrackIsReadable() throws {
        let url = directory.appendingPathComponent("t.caf")
        var track: AlignedTrackWriter? = try AlignedTrackWriter(url: url, channels: 2, sessionStart: 0)
        track?.write(buffer(2, value: 0.5, channels: 2), bufferTime: 0, arrivalHostTime: 0)
        // Copie du fichier tel qu'il est sur le disque pendant l'enregistrement
        let snapshot = directory.appendingPathComponent("snapshot.caf")
        try FileManager.default.copyItem(at: url, to: snapshot)
        track = nil
        let file = try AVAudioFile(forReading: snapshot)
        XCTAssertEqual(Double(file.length), 2 * sr, accuracy: 4096)
    }

    func testMixerCombinesTracksAndVerifiesDuration() throws {
        let system = try AlignedTrackWriter(url: directory.appendingPathComponent("system.caf"), channels: 2, sessionStart: 0)
        let mic = try AlignedTrackWriter(url: directory.appendingPathComponent("mic.caf"), channels: 1, sessionStart: 0)
        system.write(buffer(3, value: 0.25, channels: 2), bufferTime: 0, arrivalHostTime: 0)
        mic.write(buffer(2, value: 0.25, channels: 1), bufferTime: 1, arrivalHostTime: 1)
        system.close()
        mic.close()

        let output = try RecordingMixer.mix(
            tracks: [system.url, mic.url],
            to: directory.appendingPathComponent("final.m4a")
        )
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 3, accuracy: 0.1)
    }

    func testMixerKeepsWorkingWithOneMissingTrack() throws {
        let system = try AlignedTrackWriter(url: directory.appendingPathComponent("system.caf"), channels: 2, sessionStart: 0)
        system.write(buffer(1, value: 0.25, channels: 2), bufferTime: 0, arrivalHostTime: 0)
        system.close()
        let output = try RecordingMixer.mix(
            tracks: [system.url, directory.appendingPathComponent("mic.caf")],
            to: directory.appendingPathComponent("final.m4a")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    /// Un fichier final tronque (mixage interrompu) ne doit jamais etre pris pour complet
    func testTruncatedFinalFileIsRejected() throws {
        let track = try AlignedTrackWriter(url: directory.appendingPathComponent("system.caf"), channels: 2, sessionStart: 0)
        track.write(buffer(10, value: 0.25, channels: 2), bufferTime: 0, arrivalHostTime: 0)
        track.close()
        let short = try AlignedTrackWriter(url: directory.appendingPathComponent("short.caf"), channels: 2, sessionStart: 0)
        short.write(buffer(2, value: 0.25, channels: 2), bufferTime: 0, arrivalHostTime: 0)
        short.close()

        let expected = RecordingMixer.expectedDuration(of: [track.url])
        XCTAssertEqual(expected, 10, accuracy: 0.01)
        XCTAssertThrowsError(try RecordingMixer.verify(short.url, expected: expected))
        XCTAssertNoThrow(try RecordingMixer.verify(track.url, expected: expected))
    }

    func testMixLeavesNoPartialFile() throws {
        let track = try AlignedTrackWriter(url: directory.appendingPathComponent("system.caf"), channels: 2, sessionStart: 0)
        track.write(buffer(1, value: 0.25, channels: 2), bufferTime: 0, arrivalHostTime: 0)
        track.close()
        _ = try RecordingMixer.mix(tracks: [track.url], to: directory.appendingPathComponent("final.m4a"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains("partial") }, "\(names)")
    }

    func testMixerFailsWithoutAnyTrack() {
        XCTAssertThrowsError(try RecordingMixer.mix(
            tracks: [directory.appendingPathComponent("none.caf")],
            to: directory.appendingPathComponent("final.m4a")
        ))
    }
}

/// Sortie du moteur : aucune ligne JSON perdue.
final class JSONLineReaderTests: XCTestCase {
    private func collect(_ feed: (JSONLineReader) -> Void) -> [PythonMessage] {
        var messages: [PythonMessage] = []
        let reader = JSONLineReader { messages.append($0) }
        feed(reader)
        return messages
    }

    func testAccentSplitAcrossChunksIsNotLost() {
        let line = Data(#"{"type":"log","level":"info","message":"réunion terminée"}"#.utf8) + Data("\n".utf8)
        // Coupure au milieu du "é" (2 octets en UTF-8)
        let cut = line.firstIndex(of: 0xC3)! + 1
        let messages = collect { reader in
            reader.feed(line[..<cut])
            reader.feed(line[cut...])
        }
        XCTAssertEqual(messages.count, 1)
        if case .log(let log) = messages.first {
            XCTAssertEqual(log.message, "réunion terminée")
        } else {
            XCTFail("message log attendu")
        }
    }

    func testLastLineWithoutNewlineIsFlushed() {
        let messages = collect { reader in
            reader.feed(Data(#"{"type":"log","level":"info","message":"a"}"#.utf8) + Data("\n".utf8))
            reader.feed(Data(#"{"type":"log","level":"info","message":"b"}"#.utf8))
            reader.flush()
        }
        XCTAssertEqual(messages.count, 2)
    }
}

final class BridgeCompletionTests: XCTestCase {
    func testCompletesOnceAfterExitAndEOF() {
        let completion = BridgeCompletion()
        var calls: [Int32] = []
        completion.onComplete = { calls.append($0) }
        completion.processDidExit(status: 0)
        XCTAssertTrue(calls.isEmpty, "la sortie n'est pas encore lue")
        completion.stdoutDidClose()
        completion.stdoutDidClose()
        XCTAssertEqual(calls, [0])
    }
}

final class ObjCExceptionGuardTests: XCTestCase {
    /// Une exception Objective-C (comme celles d'AVAudioEngine) devient une erreur Swift
    func testObjCExceptionBecomesSwiftError() {
        XCTAssertThrowsError(try RecordingService.guarded("test") {
            _ = NSArray().object(at: 3)
        })
        XCTAssertNoThrow(try RecordingService.guarded("test") {})
    }
}

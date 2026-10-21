import XCTest
@testable import VoxaEngine

// Memes cas que tests/python/test_transcribe_bridge.py : les deux moteurs
// doivent se comporter pareil.

private func words(_ text: String, start: Double = 0, step: Double = 0.3) -> [Word] {
    text.split(separator: " ").enumerated().map { i, w in
        Word(text: " " + w, start: start + Double(i) * step, end: start + Double(i) * step + step * 0.8)
    }
}

private func joined(_ words: [Word]) -> String {
    words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
}

final class RepetitionTests: XCTestCase {
    func testSingleWordLoopCollapsed() {
        let kept = PostProcessing.collapseRepetitions(words("pour le fnb " + String(repeating: "la ", count: 60) + "et voilà"))
        XCTAssertEqual(joined(kept), "pour le fnb la et voilà")
    }

    func testPhraseLoopCollapsed() {
        let kept = PostProcessing.collapseRepetitions(words(String(repeating: "ok on y va ", count: 6) + "fin"))
        XCTAssertEqual(joined(kept), "ok on y va fin")
    }

    func testNaturalRepetitionKept() {
        let text = "non non non je ne pense pas"
        XCTAssertEqual(joined(PostProcessing.collapseRepetitions(words(text))), text)
    }

    func testPunctuationAndCaseIgnored() {
        XCTAssertEqual(PostProcessing.collapseRepetitions(words("Voilà, voilà. voilà voilà voilà ok")).count, 2)
    }
}

final class SplitBySpeakerTests: XCTestCase {
    func testSegmentSplitAtSpeakerChange() {
        let w = [Word(text: " je", start: 0, end: 0.3), Word(text: " t'explique", start: 0.3, end: 0.9),
                 Word(text: " en", start: 0.9, end: 1.1), Word(text: " fait", start: 2.1, end: 2.4),
                 Word(text: " c'est", start: 2.4, end: 2.8), Word(text: " simple", start: 2.8, end: 3.5)]
        let out = PostProcessing.splitBySpeaker(
            [TranscriptSegment(start: 0, end: 4, text: "", words: w)],
            turns: [SpeakerTurn(start: 0, end: 1.5, speaker: "B"), SpeakerTurn(start: 1.8, end: 4, speaker: "A")]
        )
        XCTAssertEqual(out.map { $0.speaker! + ":" + $0.text }, ["B:je t'explique en", "A:fait c'est simple"])
    }

    func testIsolatedWordStaysInSentence() {
        let w = words("La réserve légale, c'est 5% du bénéfice dans la limite de 10% du capital.", step: 0.4)
        let out = PostProcessing.splitBySpeaker(
            [TranscriptSegment(start: 0, end: 6, text: "", words: w)],
            turns: [SpeakerTurn(start: 0, end: 2.75, speaker: "S2"), SpeakerTurn(start: 2.8, end: 3.15, speaker: "S1"),
                    SpeakerTurn(start: 3.2, end: 10, speaker: "S2")]
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.speaker, "S2")
    }

    func testGoodbyeAfterLastTurnGoesToNearestSpeaker() {
        let w = [Word(text: " Ciao,", start: 12, end: 12.3), Word(text: " ciao.", start: 12.3, end: 12.6)]
        let out = PostProcessing.splitBySpeaker(
            [TranscriptSegment(start: 12, end: 12.6, text: "", words: w)],
            turns: [SpeakerTurn(start: 0, end: 5, speaker: "A"), SpeakerTurn(start: 6, end: 10, speaker: "B")]
        )
        XCTAssertEqual(out.first?.speaker, "B")
    }

    func testFarFromAnyTurnIsUnknown() {
        let out = PostProcessing.splitBySpeaker(
            [TranscriptSegment(start: 50, end: 51, text: "x", words: [Word(text: " x", start: 50, end: 51)])],
            turns: [SpeakerTurn(start: 0, end: 4, speaker: "A")]
        )
        XCTAssertEqual(out.first?.speaker, "Inconnu")
    }
}

final class VoiceMatcherTests: XCTestCase {
    func testParsesV1AndV2() {
        XCTAssertEqual(VoiceMatcher.parseGallery(["Pierre": [0.1, 0.2]]), ["Pierre": [[0.1, 0.2]]])
        let v2: [String: Any] = ["version": 2, "speakers": ["Pierre": [["embedding": [1.0, 0.0]], ["embedding": [0.0, 1.0]]]]]
        XCTAssertEqual(VoiceMatcher.parseGallery(v2), ["Pierre": [[1, 0], [0, 1]]])
    }

    func testBestSampleWinsAndNoDuplicates() {
        let gallery: [String: [[Double]]] = ["Pierre": [[1, 0, 0], [0, 1, 0]], "Olivier": [[0, 0, 1]]]
        let result = VoiceMatcher.match(["S0": [0.05, 1, 0], "S1": [0, 0.9, 0.1]], gallery: gallery)
        XCTAssertEqual(result.matches, ["S0": "Pierre"])
        XCTAssertGreaterThan(result.scores["S0"] ?? 0, 0.99)
    }

    func testIgnoresOtherDimensions() {
        let scores = VoiceMatcher.scores(["S": [1, 0]], gallery: ["A": [[1, 0], [1, 0, 0]]])
        XCTAssertEqual(scores["S"]?["A"] ?? 0, 1, accuracy: 1e-9)
    }
}

final class SpuriousSpeakerTests: XCTestCase {
    func testTinyClusterIsSpurious() {
        // Extrait de 5 min : 6 s de "parole" isolee pour SPEAKER_03
        let turns = [SpeakerTurn(start: 0, end: 130, speaker: "A"), SpeakerTurn(start: 130, end: 230, speaker: "B"),
                     SpeakerTurn(start: 230, end: 242, speaker: "C"), SpeakerTurn(start: 300, end: 306, speaker: "D")]
        XCTAssertEqual(PostProcessing.spuriousSpeakers(turns, audioDuration: 330), ["D"])
    }

    func testShortRecordingKeepsShortSpeakers() {
        // Enregistrement de 60 s : 3 % = 1,8 s, une reponse de 4 s est legitime
        let turns = [SpeakerTurn(start: 0, end: 50, speaker: "A"), SpeakerTurn(start: 50, end: 54, speaker: "B")]
        XCTAssertTrue(PostProcessing.spuriousSpeakers(turns, audioDuration: 60).isEmpty)
    }

    func testShortSpeakerUnlikeEveryoneIsArtifact() {
        // 9 s en fin d'appel, empreinte sans ressemblance avec les 3 vraies voix
        let turns = [SpeakerTurn(start: 0, end: 175, speaker: "A"), SpeakerTurn(start: 175, end: 283, speaker: "B"),
                     SpeakerTurn(start: 283, end: 299, speaker: "C"), SpeakerTurn(start: 319, end: 328, speaker: "D")]
        let embeddings: [String: [Double]] = ["A": [1, 0.3, 0.2, 0], "B": [0.3, 1, 0.25, 0], "C": [0.25, 0.3, 1, 0],
                                              "D": [0, 0, 0, 1]]
        XCTAssertEqual(PostProcessing.spuriousSpeakers(turns, audioDuration: 330, embeddings: embeddings), ["D"])
        // ... sauf si c'est une voix connue
        XCTAssertTrue(PostProcessing.spuriousSpeakers(turns, audioDuration: 330, embeddings: embeddings, keep: ["D"]).isEmpty)
    }

    func testShortRealSpeakerIsKept() {
        // Hugo : 16 s, ressemblance normale (0,3) avec les autres
        let turns = [SpeakerTurn(start: 0, end: 175, speaker: "A"), SpeakerTurn(start: 175, end: 191, speaker: "H")]
        let embeddings: [String: [Double]] = ["A": [1, 0.3], "H": [0.3, 1]]
        XCTAssertTrue(PostProcessing.spuriousSpeakers(turns, audioDuration: 330, embeddings: embeddings).isEmpty)
    }

    func testSingleSpeakerNeverRemoved() {
        XCTAssertTrue(PostProcessing.spuriousSpeakers([SpeakerTurn(start: 0, end: 2, speaker: "A")], audioDuration: 600).isEmpty)
    }
}

// Preparation des modeles (premier lancement de l'edition App Store)
final class ModelPreparationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int = 10) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func writeModel(_ engine: NativeEngine) throws {
        let folder = "models/argmaxinc/whisperkit-coreml/openai_whisper-\(engine.whisperVariant)"
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try write("\(folder)/\(name).mlmodelc/coremldata.bin")
        }
    }

    func testTreeSizeUsesLFSSize() throws {
        let json = """
        [{"type":"file","path":"a/config.json","size":120},
         {"type":"file","path":"a/AudioEncoder.mlmodelc/weights/weight.bin","size":134,"lfs":{"size":1200000000}},
         {"type":"directory","path":"a/AudioEncoder.mlmodelc","size":0}]
        """
        XCTAssertEqual(try NativeEngine.parseTreeSize(Data(json.utf8)), 1_200_000_120)
    }

    func testDownloadFraction() {
        XCTAssertNil(PreparationProgress(phase: .downloading).downloadFraction)
        XCTAssertEqual(PreparationProgress(phase: .downloading, bytesDownloaded: 25, bytesTotal: 100).downloadFraction, 0.25)
        XCTAssertEqual(PreparationProgress(phase: .downloading, bytesDownloaded: 120, bytesTotal: 100).downloadFraction, 1)
    }

    func testModelFolderLayoutMatchesHubCache() {
        let engine = NativeEngine(modelsDirectory: root)
        XCTAssertEqual(
            engine.whisperModelFolder.path,
            root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(NativeEngine.whisperModel)").path
        )
    }

    func testCompleteDetection() throws {
        let engine = NativeEngine(modelsDirectory: root)
        XCTAssertFalse(engine.isWhisperModelDownloaded)
        // Dossier telecharge par une version precedente (sans marqueur) : accepte
        try writeModel(engine)
        XCTAssertTrue(engine.isWhisperModelDownloaded)
        // Un fichier encore .incomplete : telechargement a reprendre
        try write("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-\(engine.whisperVariant)/AudioEncoder.mlmodelc/weights/weight.bin.abc.incomplete")
        XCTAssertFalse(engine.isWhisperModelDownloaded)
        // Le marqueur ecrit apres un telechargement complet fait foi
        try write("models/argmaxinc/whisperkit-coreml/openai_whisper-\(engine.whisperVariant)/\(NativeEngine.completeMarker)", bytes: 0)
        XCTAssertTrue(engine.isWhisperModelDownloaded)
    }

    func testBytesOnDiskCountsIncompleteButNotMetadata() throws {
        try write("a/weight.bin", bytes: 1000)
        try write("cache/weight.bin.etag.incomplete", bytes: 500)
        try write("cache/weight.bin.metadata", bytes: 80)
        XCTAssertEqual(NativeEngine.bytesOnDisk([root.appendingPathComponent("a"), root.appendingPathComponent("cache")]), 1500)
    }

    func testRemoveOtherVariantsKeepsCurrent() throws {
        let old = NativeEngine(modelsDirectory: root, whisperVariant: "large-v3-v20240930_turbo")
        let new = NativeEngine(modelsDirectory: root, whisperVariant: "large-v3-v20240930_turbo_632MB")
        try writeModel(old)
        try writeModel(new)
        try write("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-large-v3-v20240930_turbo/x.metadata")
        try write("models/argmaxinc/whisperkit-coreml/config.json")
        let removed = new.removeOtherWhisperVariants()
        XCTAssertEqual(removed.count, 2)
        XCTAssertFalse(old.isWhisperModelDownloaded)
        XCTAssertTrue(new.isWhisperModelDownloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/config.json").path))
    }

    func testNetworkErrorDetection() {
        XCTAssertTrue(NativeEngine.isNetworkError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NativeEngine.isNetworkError(URLError(.timedOut)))
        let wrapped = NSError(domain: "WhisperKit", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        XCTAssertTrue(NativeEngine.isNetworkError(wrapped))
        XCTAssertFalse(NativeEngine.isNetworkError(NSError(domain: "CoreML", code: 3, userInfo: [NSLocalizedDescriptionKey: "Model file not found"])))
    }
}

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

    func testSingleSpeakerNeverRemoved() {
        XCTAssertTrue(PostProcessing.spuriousSpeakers([SpeakerTurn(start: 0, end: 2, speaker: "A")], audioDuration: 600).isEmpty)
    }
}

import SwiftData
import XCTest
@testable import Voxa

// MARK: - Helpers

private func result(_ id: Int, _ start: Double, _ end: Double, _ text: String, _ speaker: String?) -> ResultSegment {
    ResultSegment(id: id, start: start, end: end, text: text, speaker: speaker, avgLogprob: nil, noSpeechProb: nil)
}

@MainActor
private func makeProject(in context: ModelContext) -> TranscriptionProject {
    let project = TranscriptionProject.create(audioURL: URL(fileURLWithPath: "/tmp/Réunion.m4a"))
    context.insert(project)
    let segments = [
        result(0, 0, 4.5, "Bonjour à tous.", "SPEAKER_00"),
        result(1, 4.5, 9.25, "Merci, on commence.", "SPEAKER_01"),
        result(2, 9.25, 12, "Premier point.", "SPEAKER_01"),
    ]
    for res in segments {
        let segment = Segment.create(from: res, project: project)
        context.insert(segment)
        project.segments.append(segment)
    }
    project.speakerNames = ["SPEAKER_00": "Olivier"]
    return project
}

// MARK: - Fusion des segments

final class MergeSegmentsTests: XCTestCase {
    func testMergesConsecutiveSegmentsOfSameSpeaker() {
        let merged = TranscriptionListVM.mergeConsecutiveSpeakerSegments([
            result(0, 0, 2, "Bonjour", "SPEAKER_00"),
            result(1, 2, 4, "à tous", "SPEAKER_00"),
            result(2, 4, 6, "Salut", "SPEAKER_01"),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "Bonjour à tous")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 4)
        XCTAssertEqual(merged[1].speaker, "SPEAKER_01")
    }

    func testKeepsSegmentsWithoutSpeakerSeparate() {
        let merged = TranscriptionListVM.mergeConsecutiveSpeakerSegments([
            result(0, 0, 2, "a", nil),
            result(1, 2, 4, "b", nil),
            result(2, 4, 6, "c", ""),
        ])
        XCTAssertEqual(merged.count, 3)
    }

    func testAlternatingSpeakersAreNotMerged() {
        let merged = TranscriptionListVM.mergeConsecutiveSpeakerSegments([
            result(0, 0, 1, "a", "A"), result(1, 1, 2, "b", "B"), result(2, 2, 3, "c", "A"),
        ])
        XCTAssertEqual(merged.map(\.text), ["a", "b", "c"])
    }
}

// MARK: - Modele

@MainActor
final class TranscriptionProjectTests: XCTestCase {
    var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: TranscriptionProject.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testCreateFromAudioURL() {
        let project = TranscriptionProject.create(audioURL: URL(fileURLWithPath: "/tmp/Call Olivier.m4a"))
        XCTAssertEqual(project.title, "Call Olivier")
        XCTAssertEqual(project.audioFileName, "Call Olivier.m4a")
        XCTAssertEqual(project.status, .pending)
    }

    func testSpeakerNamesAndDisplayName() {
        let project = makeProject(in: container.mainContext)
        XCTAssertEqual(project.displayName(for: "SPEAKER_00"), "Olivier")
        XCTAssertEqual(project.displayName(for: "SPEAKER_01"), "SPEAKER_01")
        XCTAssertEqual(project.uniqueSpeakers, ["SPEAKER_00", "SPEAKER_01"])
    }

    func testMeetingReportRoundTrip() {
        let project = makeProject(in: container.mainContext)
        XCTAssertNil(project.meetingReport)
        project.meetingReport = "# Compte rendu"
        XCTAssertEqual(project.meetingReport, "# Compte rendu")
    }

    func testSortedSegmentsFollowIndex() {
        let project = makeProject(in: container.mainContext)
        XCTAssertEqual(project.sortedSegments.map(\.index), [0, 1, 2])
    }
}

// MARK: - Exports

@MainActor
final class ExportServiceTests: XCTestCase {
    var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: TranscriptionProject.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testTXTUsesSpeakerNames() {
        let txt = ExportService.export(project: makeProject(in: container.mainContext), format: .txt)
        let lines = txt.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "[00:00:00 - 00:00:04] Olivier : Bonjour à tous.")
        XCTAssertEqual(lines.count, 3)
    }

    func testTXTPutsReportFirst() {
        let project = makeProject(in: container.mainContext)
        project.meetingReport = "Décisions : aucune"
        let txt = ExportService.export(project: project, format: .txt)
        XCTAssertTrue(txt.hasPrefix("=== COMPTE RENDU DE REUNION ===\n\nDécisions : aucune"))
    }

    func testSRT() {
        let srt = ExportService.export(project: makeProject(in: container.mainContext), format: .srt)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:04,500\n[Olivier] Bonjour à tous.\n"))
        XCTAssertTrue(srt.contains("2\n00:00:04,500 --> 00:00:09,250\n[SPEAKER_01] Merci, on commence.\n"))
    }

    func testMarkdownGroupsConsecutiveTurns() {
        let md = ExportService.export(project: makeProject(in: container.mainContext), format: .md)
        XCTAssertTrue(md.hasPrefix("# Réunion\n\n## Transcription\n\n"))
        XCTAssertTrue(md.contains("**SPEAKER_01** _00:00:04_\n\nMerci, on commence. Premier point.\n\n"))
    }

    func testJSONIsValidAndNamed() throws {
        let json = ExportService.export(project: makeProject(in: container.mainContext), format: .json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let segments = try XCTUnwrap(root["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0]["speaker"] as? String, "Olivier")
    }
}

// MARK: - API locale

final class LocalAPIParserTests: XCTestCase {
    private func raw(_ string: String) -> Data { Data(string.utf8) }

    func testParsesRequestWithQueryAndBody() throws {
        let body = #"{"path":"/Users/x/a.m4a"}"#
        let data = raw("POST /transcriptions?limit=5&query=olivier HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer abc\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        let request = try XCTUnwrap(LocalAPIServer.parse(data))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/transcriptions")
        XCTAssertEqual(request.query, ["limit": "5", "query": "olivier"])
        XCTAssertEqual(request.headers["authorization"], "Bearer abc")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testIncompleteHeadersReturnNil() {
        XCTAssertNil(LocalAPIServer.parse(raw("GET /health HTTP/1.1\r\nHost: x\r\n")))
    }

    func testIncompleteBodyReturnsNil() {
        XCTAssertNil(LocalAPIServer.parse(raw("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":")))
    }

    func testRequestWithoutBody() throws {
        let request = try XCTUnwrap(LocalAPIServer.parse(raw("GET /health HTTP/1.1\r\n\r\n")))
        XCTAssertEqual(request.path, "/health")
        XCTAssertTrue(request.body.isEmpty)
    }
}

// MARK: - Utilitaires

final class UtilitiesTests: XCTestCase {
    func testTimestamps() {
        XCTAssertEqual(TimeFormatting.timestamp(3725), "01:02:05")
        XCTAssertEqual(TimeFormatting.srtTimestamp(4.5), "00:00:04,500")
        XCTAssertEqual(TimeFormatting.shortTimestamp(125), "2:05")
        XCTAssertEqual(TimeFormatting.durationText(3900), "1h 5min")
    }

    func testVideoDetection() {
        XCTAssertTrue(TranscriptionListVM.isVideo(URL(fileURLWithPath: "/a/call.mov")))
        XCTAssertTrue(TranscriptionListVM.isVideo(URL(fileURLWithPath: "/a/call.MP4")))
        XCTAssertFalse(TranscriptionListVM.isVideo(URL(fileURLWithPath: "/a/call.m4a")))
        XCTAssertFalse(TranscriptionListVM.isVideo(URL(fileURLWithPath: "/a/call.wav")))
    }
}

// MARK: - Sortie d'erreur Python

final class StderrTailTests: XCTestCase {
    func testKeepsOnlyTheEnd() {
        let tail = StderrTail(maxBytes: 10)
        tail.append(Data("0123456789".utf8))
        tail.append(Data("ABCDE".utf8))
        XCTAssertEqual(tail.text, "56789ABCDE")
    }

    func testIgnoresEmptyChunks() {
        let tail = StderrTail()
        tail.append(Data())
        XCTAssertEqual(tail.text, "")
    }

    func testConcurrentAppends() {
        let tail = StderrTail(maxBytes: 1_000_000)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            tail.append(Data("x".utf8))
        }
        XCTAssertEqual(tail.text.count, 100)
    }
}

// MARK: - Jeton HuggingFace (Trousseau)

final class HuggingFaceTokenTests: XCTestCase {
    private var suite: UserDefaults!

    override func setUp() {
        HuggingFaceToken.service = "com.pierre.Voxa.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: "VoxaTests.\(UUID().uuidString)")
        HuggingFaceToken.defaults = suite
        HuggingFaceToken.resetCache()
    }

    override func tearDown() {
        HuggingFaceToken.value = ""
        HuggingFaceToken.service = "com.pierre.Voxa"
        HuggingFaceToken.defaults = .standard
        HuggingFaceToken.resetCache()
    }

    func testSetReadAndClear() {
        XCTAssertFalse(HuggingFaceToken.isSet)
        HuggingFaceToken.value = "  hf_abc  "
        XCTAssertEqual(HuggingFaceToken.value, "hf_abc")
        HuggingFaceToken.value = "hf_new"
        XCTAssertEqual(HuggingFaceToken.value, "hf_new")
        HuggingFaceToken.value = ""
        XCTAssertFalse(HuggingFaceToken.isSet)
    }

    func testValueIsReadFromKeychainAfterCacheReset() {
        HuggingFaceToken.value = "hf_persisted"
        HuggingFaceToken.resetCache()
        XCTAssertEqual(HuggingFaceToken.value, "hf_persisted")
    }

    func testMigrationMovesLegacyTokenAndRemovesIt() {
        suite.set("hf_legacy", forKey: "hf_token")
        HuggingFaceToken.migrateFromUserDefaults()
        XCTAssertEqual(HuggingFaceToken.value, "hf_legacy")
        XCTAssertNil(suite.string(forKey: "hf_token"))
    }

    func testMigrationKeepsExistingKeychainToken() {
        HuggingFaceToken.value = "hf_keychain"
        suite.set("hf_legacy", forKey: "hf_token")
        HuggingFaceToken.migrateFromUserDefaults()
        XCTAssertEqual(HuggingFaceToken.value, "hf_keychain")
        XCTAssertNil(suite.string(forKey: "hf_token"))
    }
}

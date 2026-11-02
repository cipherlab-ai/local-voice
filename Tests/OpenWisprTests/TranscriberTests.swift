import Darwin
import XCTest
@testable import OpenWisprLib

final class TranscriberTests: XCTestCase {
    func testModelSearchIncludesCurrentLegacyAndWhisperCppCaches() {
        let home = URL(fileURLWithPath: "/tmp/local-voice-home")
        let config = URL(fileURLWithPath: "/tmp/local-voice-config")
        let resources = URL(fileURLWithPath: "/tmp/local-voice-resources")

        let paths = Transcriber.modelSearchPaths(
            modelSize: "base.en",
            homeDirectory: home,
            configDirectory: config,
            resourceDirectory: resources
        )

        XCTAssertTrue(
            paths.contains(
                "/tmp/local-voice-config/models/ggml-base.en.bin"
            )
        )
        XCTAssertTrue(
            paths.contains(
                "/tmp/local-voice-home/.config/open-wispr/models/ggml-base.en.bin"
            )
        )
        XCTAssertTrue(
            paths.contains(
                "/tmp/local-voice-home/.cache/whisper-cpp/ggml-base.en.bin"
            )
        )
        XCTAssertTrue(
            paths.contains(
                "/tmp/local-voice-resources/models/ggml-base.en.bin"
            )
        )
    }


    func testBlankAudioMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioWithWhitespace() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("  [BLANK_AUDIO]  "), "")
    }

    func testMultipleMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] [silence]"), "")
    }

    func testParenthesizedMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(BLANK_AUDIO)"), "")
    }

    func testNonSpeechEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Music] [Applause]"), "")
    }

    func testMarkerMixedWithText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testMarkerAtStartOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] hello"), "hello")
    }

    func testMarkerAtEndOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO]"), "hello")
    }

    func testNormalTextUnchanged() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(""), "")
    }

    func testUnknownBracketsPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("see [1] and (later)"), "see [1] and (later)")
    }

    func testKnownMarkerStrippedUnknownPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] see [1]"), "see [1]")
    }

    func testMultiWordAudioEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[MUSIC PLAYING]"), "")
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(dramatic music)"), "")
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[upbeat music playing]"), "")
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(crowd cheering)"), "")
    }

    func testMultiWordMarkerMixedWithText() {
        XCTAssertEqual(
            Transcriber.stripWhisperMarkers("hello (dramatic music) world"),
            "hello world"
        )
    }

    func testBracketedSpeechWordsPreserved() {
        XCTAssertEqual(
            Transcriber.stripWhisperMarkers("(sound good)"),
            "(sound good)"
        )
        XCTAssertEqual(
            Transcriber.stripWhisperMarkers("note (later)"),
            "note (later)"
        )
    }
}

final class TranscriberProcessTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var audioURL: URL!
    private var modelPath: String!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriberProcessTests-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        ))
        audioURL = temporaryDirectory.appendingPathComponent("take.wav")
        XCTAssertNoThrow(try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL))
        let modelURL = temporaryDirectory.appendingPathComponent("ggml-test.bin")
        XCTAssertNoThrow(try Data([0x01]).write(to: modelURL))
        modelPath = modelURL.path
    }

    override func tearDown() {
        XCTAssertNoThrow(try FileManager.default.removeItem(at: temporaryDirectory))
        super.tearDown()
    }

    private func makeStub(_ body: String) -> String {
        let stubURL = temporaryDirectory.appendingPathComponent("whisper-stub.sh")
        do {
            try "#!/bin/sh\n\(body)\n".write(to: stubURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: stubURL.path
            )
        } catch {
            XCTFail("Failed to create whisper stub: \(error)")
        }
        return stubURL.path
    }

    private func makeTranscriber(
        binary: String?,
        model: String?,
        timeout: TimeInterval = 10
    ) -> Transcriber {
        Transcriber(
            modelSize: "test",
            language: "en",
            whisperBinaryResolver: { binary },
            modelResolver: { _ in model },
            timeoutResolver: { _ in timeout }
        )
    }

    private func processIsDead(_ pid: Int32, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    func testMissingBinaryThrowsWhisperNotFound() {
        let transcriber = makeTranscriber(binary: nil, model: modelPath)

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audioURL)) { error in
            guard case TranscriberError.whisperNotFound = error else {
                return XCTFail("expected whisperNotFound, got \(error)")
            }
        }
        XCTAssertFalse(transcriber.isAvailable())
    }

    func testMissingModelThrowsModelNotFound() {
        let transcriber = makeTranscriber(binary: makeStub("exit 0"), model: nil)

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audioURL)) { error in
            guard case TranscriberError.modelNotFound(let size) = error else {
                return XCTFail("expected modelNotFound, got \(error)")
            }
            XCTAssertEqual(size, "test")
        }
    }

    func testSuccessfulRunReturnsStrippedStdout() throws {
        let transcriber = makeTranscriber(
            binary: makeStub("echo \"hello [BLANK_AUDIO] world\""),
            model: modelPath
        )

        XCTAssertEqual(try transcriber.transcribe(audioURL: audioURL), "hello world")
        XCTAssertTrue(transcriber.isAvailable())
    }

    func testNonZeroExitThrowsTranscriptionFailed() {
        let transcriber = makeTranscriber(
            binary: makeStub("echo \"partial text\"\necho \"boom\" >&2\nexit 1"),
            model: modelPath
        )

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audioURL)) { error in
            guard case TranscriberError.transcriptionFailed = error else {
                return XCTFail("expected transcriptionFailed, got \(error)")
            }
        }
    }

    func testTimeoutThrowsAndKillsProcessIgnoringSIGTERM() throws {
        let pidFile = temporaryDirectory.appendingPathComponent("stub.pid")
        let transcriber = makeTranscriber(
            binary: makeStub("trap '' TERM\necho $$ > \"\(pidFile.path)\"\nexec sleep 30"),
            model: modelPath,
            timeout: 0.5
        )
        let startedAt = Date()

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audioURL)) { error in
            guard case TranscriberError.timeout = error else {
                return XCTFail("expected timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)

        guard
            let pidContents = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(pidContents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return XCTFail("whisper-cli stub did not write its pid")
        }
        defer { _ = Darwin.kill(pid, SIGKILL) }

        XCTAssertTrue(
            processIsDead(pid, within: 6),
            "whisper-cli stub still running after timeout; SIGKILL fallback did not fire"
        )
    }

    func testTimeoutKillsCooperativeProcessViaTerminate() throws {
        let pidFile = temporaryDirectory.appendingPathComponent("stub.pid")
        let transcriber = makeTranscriber(
            binary: makeStub("echo $$ > \"\(pidFile.path)\"\nexec sleep 30"),
            model: modelPath,
            timeout: 0.5
        )

        XCTAssertThrowsError(try transcriber.transcribe(audioURL: audioURL)) { error in
            guard case TranscriberError.timeout = error else {
                return XCTFail("expected timeout, got \(error)")
            }
        }

        guard
            let pidContents = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(pidContents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return XCTFail("whisper-cli stub did not write its pid")
        }
        defer { _ = Darwin.kill(pid, SIGKILL) }

        XCTAssertTrue(
            processIsDead(pid, within: 3),
            "whisper-cli stub still running after timeout"
        )
    }
}

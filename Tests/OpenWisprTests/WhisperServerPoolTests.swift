import Foundation
import XCTest
@testable import OpenWisprLib

final class WhisperServerPoolTests: XCTestCase {
    func testParsesJSONTextAndStripsWhisperMarkers() throws {
        let data = Data(#"{"text":" hello [BLANK_AUDIO] world\n"}"#.utf8)

        let text = try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: data)

        XCTAssertEqual(text, "hello world")
    }

    func testJSONStringErrorThrowsServerError() {
        let data = Data(#"{"error":"failed to read audio"}"#.utf8)

        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: data)) { error in
            guard case WhisperServerError.serverError(let message) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(message, "failed to read audio")
        }
    }

    func testJSONErrorTakesPrecedenceOverText() {
        let data = Data(#"{"error":"boom","text":"ignored"}"#.utf8)

        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: data)) { error in
            guard case WhisperServerError.serverError(let message) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(message, "boom")
        }
    }

    func testJSONDictionaryWithoutTextOrErrorThrowsServerError() {
        let data = Data(#"{"segments":[]}"#.utf8)

        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: data)) { error in
            guard case WhisperServerError.serverError(let message) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(message, "response missing \"text\"")
        }
    }

    func testPlainTextResponseIsTrimmed() throws {
        let data = Data(" plain transcript ".utf8)

        let text = try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: data)

        XCTAssertEqual(text, "plain transcript")
    }

    func testNilStatusCodeAcceptsPlainTextResponse() throws {
        let data = Data("plain transcript".utf8)

        let text = try WhisperServerPool.parseInferenceResponse(statusCode: nil, data: data)

        XCTAssertEqual(text, "plain transcript")
    }

    func testEmptyDataThrowsEmptyResponse() {
        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: Data())) { error in
            guard case WhisperServerError.emptyResponse = error else {
                XCTFail("Expected emptyResponse, got \(error)")
                return
            }
        }
    }

    func testNilDataThrowsEmptyResponse() {
        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 200, data: nil)) { error in
            guard case WhisperServerError.emptyResponse = error else {
                XCTFail("Expected emptyResponse, got \(error)")
                return
            }
        }
    }

    func testNon200StatusThrowsHTTPErrorBeforeParsingBody() {
        let data = Data(#"{"text":"x"}"#.utf8)

        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 500, data: data)) { error in
            guard case WhisperServerError.httpError(let code) = error else {
                XCTFail("Expected httpError, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
        }
    }

    func testNon200StatusThrowsHTTPErrorWithNilData() {
        XCTAssertThrowsError(try WhisperServerPool.parseInferenceResponse(statusCode: 404, data: nil)) { error in
            guard case WhisperServerError.httpError(let code) = error else {
                XCTFail("Expected httpError, got \(error)")
                return
            }
            XCTAssertEqual(code, 404)
        }
    }

    func testServerErrorIsNotATimeout() {
        XCTAssertFalse(InferenceTimeout.isTimeout(WhisperServerError.serverError("x")))
    }
}

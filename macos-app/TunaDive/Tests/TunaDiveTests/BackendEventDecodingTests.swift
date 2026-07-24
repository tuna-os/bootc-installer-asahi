import XCTest
@testable import TunaDive

/// Fixtures below are copied verbatim from asahi-installer's docs/json-mode.md
/// (hanthor/asahi-installer@json-machine-mode) — keep them in sync with that
/// doc, not the other way around. UNVERIFIED: no Swift toolchain was
/// available to run `swift test` while writing this; run it on a real Mac
/// before trusting these pass.
final class BackendEventDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> BackendEvent {
        try JSONDecoder().decode(BackendEvent.self, from: Data(json.utf8))
    }

    func testDecodeMessage() throws {
        let event = try decode(#"{"event": "message", "level": "error", "text": "disk too small"}"#)
        guard case .message(let msg) = event else { return XCTFail("expected .message") }
        XCTAssertEqual(msg.level, .error)
        XCTAssertEqual(msg.text, "disk too small")
    }

    func testDecodeAskInput() throws {
        let event = try decode(#"{"event": "ask", "kind": "input", "id": "abc", "prompt": "OS name"}"#)
        guard case .ask(let ask) = event else { return XCTFail("expected .ask") }
        XCTAssertEqual(ask.kind, .input)
        XCTAssertEqual(ask.id, "abc")
        XCTAssertNil(ask.options)
    }

    func testDecodeAskChoice() throws {
        let json = #"""
        {"event": "ask", "kind": "choice", "id": "abc", "prompt": "Pick an OS",
         "options": {"1": "Fedora Asahi Remix", "2": "Ubuntu Asahi"}, "default": "1"}
        """#
        let event = try decode(json)
        guard case .ask(let ask) = event else { return XCTFail("expected .ask") }
        XCTAssertEqual(ask.kind, .choice)
        XCTAssertEqual(ask.options?["2"], "Ubuntu Asahi")
        XCTAssertEqual(ask.defaultValue, .string("1"))
    }

    func testDecodeAskSizeCarriesByteCounts() throws {
        let json = #"""
        {"event": "ask", "kind": "size", "id": "abc", "prompt": "New size",
         "default": "max", "min": 10737418240, "max": 494384795648, "total": 494384795648}
        """#
        let event = try decode(json)
        guard case .ask(let ask) = event else { return XCTFail("expected .ask") }
        XCTAssertEqual(ask.kind, .size)
        XCTAssertEqual(ask.min, 10_737_418_240)
        XCTAssertEqual(ask.total, 494_384_795_648)
    }

    func testDecodeAskYesnoDefaultIsBool() throws {
        let event = try decode(#"{"event": "ask", "kind": "yesno", "id": "abc", "prompt": "Continue?", "default": false}"#)
        guard case .ask(let ask) = event else { return XCTFail("expected .ask") }
        XCTAssertEqual(ask.defaultValue, .bool(false))
    }

    func testDecodeAskContinue() throws {
        let event = try decode(#"{"event": "ask", "kind": "continue", "id": "abc", "prompt": ""}"#)
        guard case .ask(let ask) = event else { return XCTFail("expected .ask") }
        XCTAssertEqual(ask.kind, .continueAck)
    }

    func testUnknownEventThrows() {
        XCTAssertThrowsError(try decode(#"{"event": "something-else"}"#))
    }

    func testAnswerRoundTrips() throws {
        let answer = BackendAnswer(id: "abc", value: .string("2"))
        let data = try JSONEncoder().encode(answer)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(decoded["id"], .string("abc"))
        XCTAssertEqual(decoded["value"], .string("2"))
    }
}

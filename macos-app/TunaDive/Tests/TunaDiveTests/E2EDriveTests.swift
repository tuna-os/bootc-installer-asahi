import XCTest
@testable import TunaDive

/// Covers the drive-mode directive decoder (tuna-dive-agent#6 §2). Doesn't
/// (and can't, from here) test the polling/file-I/O side of E2EDrive itself —
/// that needs a real TUNADIVE_E2E_DRIVE=1 run, not attempted yet.
final class E2EDriveTests: XCTestCase {
    private func decode(_ json: String) throws -> E2EDrive.Directive {
        try JSONDecoder().decode(E2EDrive.Directive.self, from: Data(json.utf8))
    }

    func testSelectCatalogEntry() throws {
        let d = try decode(#"{"action": "selectCatalogEntry", "imgref": "ghcr.io/tuna-os/bonito:gnome-asahi"}"#)
        guard case .selectCatalogEntry(let imgref) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(imgref, "ghcr.io/tuna-os/bonito:gnome-asahi")
    }

    func testSetHostname() throws {
        let d = try decode(#"{"action": "setHostname", "value": "test-host"}"#)
        guard case .setHostname(let value) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(value, "test-host")
    }

    func testAdvance() throws {
        let d = try decode(#"{"action": "advance"}"#)
        guard case .advance = d else { return XCTFail("wrong case") }
    }

    func testAnswerAsk() throws {
        let d = try decode(#"{"action": "answerAsk", "value": "2"}"#)
        guard case .answerAsk(let value) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(value, .string("2"))
    }

    func testAnswerAskWithoutValue() throws {
        let d = try decode(#"{"action": "answerAsk"}"#)
        guard case .answerAsk(let value) = d else { return XCTFail("wrong case") }
        XCTAssertNil(value)
    }

    func testUnknownActionThrows() {
        XCTAssertThrowsError(try decode(#"{"action": "doSomethingElse"}"#))
    }

    func testDisabledByDefault() {
        // No TUNADIVE_E2E_DRIVE env var in the test runner.
        XCTAssertFalse(E2EDrive.isEnabled)
    }
}

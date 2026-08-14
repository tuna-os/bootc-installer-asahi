import XCTest
@testable import Bootsahi

/// Covers the drive-mode directive decoder (issue #6 §2). Doesn't
/// (and can't, from here) test the polling/file-I/O side of E2EDrive itself —
/// that needs a real BOOTSAHI_E2E_DRIVE=1 run, not attempted yet.
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

    // ── the directives that make drive mode exercise the D3 slice ─────────
    //
    // Before these, the seam could pick a catalog entry, set a hostname and
    // answer an ask — it could not fill in user/Wi-Fi/LUKS or press the button
    // that starts the backend, so the half of D3 that is actually about
    // *driving the backend* had no coverage at all.

    func testSetUser() throws {
        let d = try decode(#"{"action": "setUser", "username": "tuna", "fullname": "Tuna Tester", "password": "hunter2"}"#)
        guard case .setUser(let username, let fullname, let password) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(username, "tuna")
        XCTAssertEqual(fullname, "Tuna Tester")
        // Carried as typed — the view model hashes it. See applyUser's note on
        // why the seam must not accept a pre-hashed value.
        XCTAssertEqual(password, "hunter2")
    }

    func testSetUserWithoutFullname() throws {
        let d = try decode(#"{"action": "setUser", "username": "tuna", "password": "hunter2"}"#)
        guard case .setUser(_, let fullname, _) = d else { return XCTFail("wrong case") }
        XCTAssertNil(fullname)
    }

    func testSetWifi() throws {
        let d = try decode(#"{"action": "setWifi", "ssid": "Tunanet"}"#)
        guard case .setWifi(let ssid) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(ssid, "Tunanet")
    }

    func testSetEncryption() throws {
        let d = try decode(#"{"action": "setEncryption", "type": "none"}"#)
        guard case .setEncryption(let type) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(type, "none")
    }

    func testSetFilesystem() throws {
        let d = try decode(#"{"action": "setFilesystem", "value": "ext4"}"#)
        guard case .setFilesystem(let value) = d else { return XCTFail("wrong case") }
        XCTAssertEqual(value, "ext4")
    }

    func testStartBackend() throws {
        let d = try decode(#"{"action": "startBackend"}"#)
        guard case .startBackend = d else { return XCTFail("wrong case") }
    }

    /// A directive missing a field the case requires must throw rather than
    /// decode into a half-built user — a silently empty username would produce
    /// a config the agent rejects at first boot, after the disk is repartitioned.
    func testSetUserWithoutPasswordThrows() {
        XCTAssertThrowsError(try decode(#"{"action": "setUser", "username": "tuna"}"#))
    }

    func testUnknownActionThrows() {
        XCTAssertThrowsError(try decode(#"{"action": "doSomethingElse"}"#))
    }

    func testDisabledByDefault() {
        // No BOOTSAHI_E2E_DRIVE env var in the test runner.
        XCTAssertFalse(E2EDrive.isEnabled)
    }
}

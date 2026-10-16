import XCTest
@testable import Bootsahi

/// Drive mode applying directives to the real view model.
///
/// `E2EDriveTests` covers the decoder — that a JSON line parses into the right
/// case. That is only half of a seam: a decoder that parses perfectly into a
/// directive nothing acts on is what the issue #4 audit called "decoder
/// scaffolding rather than the proposed real-GUI E2E". These tests drive
/// `InstallFlowViewModel.apply(_:)`, which is the same code path
/// `pollE2EDirective` takes when a harness drops a file in /tmp, so what is
/// covered here is what a real drive run does.
///
/// `E2EDrive.isEnabled` is false in the test runner and stays that way: `apply`
/// does not gate on it, only the polling does. So these run without touching
/// /tmp or setting environment variables.
@MainActor
final class E2EDriveApplyTests: XCTestCase {

    private func vm() -> InstallFlowViewModel {
        InstallFlowViewModel.fixture(step: .options)
    }

    // ── the fields the audit said drive mode could not reach ──────────────

    func testSetUserPopulatesTheConfig() {
        let flow = vm()
        flow.apply(.setUser(username: "tuna", fullname: "Tuna Tester", password: "hunter2"))
        XCTAssertEqual(flow.config.user?.username, "tuna")
        XCTAssertEqual(flow.config.user?.fullname, "Tuna Tester")
        // The default OptionsView applies, not nil — an account with no groups
        // is not the same account the real UI would have produced.
        XCTAssertEqual(flow.config.user?.groups, ["wheel"])
    }

    /// The property worth having a seam for at all (#21). If the drive path
    /// ever stored the password as typed, the harness would be proving the
    /// wizard works while the config carried a plaintext credential to a
    /// world-readable FAT partition.
    func testSetUserStoresOnlyAHash() {
        let flow = vm()
        flow.apply(.setUser(username: "tuna", fullname: nil, password: "hunter2"))
        let stored = flow.config.user?.password ?? ""
        XCTAssertTrue(stored.hasPrefix("$6$"), "expected a $6$ crypt hash, got \(stored)")
        XCTAssertNotEqual(stored, "hunter2")
        XCTAssertFalse(stored.contains("hunter2"))
    }

    func testSetWifiSetsAndClears() {
        let flow = vm()
        flow.apply(.setWifi(ssid: "Tunanet"))
        XCTAssertEqual(flow.config.wifi?.ssid, "Tunanet")
        // Clearing matters: "no Wi-Fi configured" is a distinct config the
        // agent has to handle, and a seam that could only ever set an SSID
        // could not produce it.
        flow.apply(.setWifi(ssid: ""))
        XCTAssertNil(flow.config.wifi)
    }

    func testSetEncryptionAndFilesystem() {
        let flow = vm()
        flow.apply(.setEncryption(type: "none"))
        XCTAssertEqual(flow.config.encryption?.type, "none")
        flow.apply(.setFilesystem("ext4"))
        XCTAssertEqual(flow.config.filesystem, "ext4")
    }

    // ── pressing the button, not just filling the form ────────────────────

    /// `startBackend` with nothing bundled and no override must fail loudly.
    ///
    /// This is the case a harness hits on a CI runner, and it is worth pinning
    /// precisely because the failure is *good*: the alternative — a silent
    /// no-op — is the exact shape of the bug this whole slice exists to fix,
    /// where the flow moved on without a backend ever running.
    func testStartBackendWithNoBackendFails() {
        let flow = InstallFlowViewModel.fixture(step: .diskSlider)
        flow.apply(.startBackend)
        guard case .failed(let reason) = flow.step else {
            return XCTFail("expected .failed, got \(flow.step)")
        }
        XCTAssertTrue(reason.contains("BOOTSAHI_BACKEND_MAIN"),
                      "the failure should name the override that fixes it, got: \(reason)")
    }

    // ── advance still walks the wizard ────────────────────────────────────

    func testAdvanceFromOptionsRequiresAHostname() {
        let flow = vm()
        flow.apply(.advance)
        // advanceToDiskSlider guards on a non-empty hostname, so this is a
        // no-op rather than a crash — assert the guard, not just the call.
        XCTAssertEqual(flow.step, .options)

        flow.apply(.setHostname("tuna-mini"))
        flow.apply(.advance)
        XCTAssertEqual(flow.step, .diskSlider)
    }

    func testSetHostnameReachesTheConfig() {
        let flow = vm()
        flow.apply(.setHostname("tuna-mini"))
        XCTAssertEqual(flow.config.hostname, "tuna-mini")
    }
}

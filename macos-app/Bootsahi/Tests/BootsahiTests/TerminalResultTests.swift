import XCTest
@testable import Bootsahi

/// Pins the fix for tuna-os/bootc-installer-asahi#25.
///
/// The backend caught every exception, printed advice, and fell through to
/// exit 0. This app treated exit 0 as its sole success observable, so a failed
/// install advanced to the recoveryOS walkthrough and told the user to bless and
/// reboot an incomplete system. `.recoveryWalkthrough` is the consequential
/// branch, so every test here is really asking: can this input reach it?
@MainActor
final class TerminalResultTests: XCTestCase {

    private func result(_ status: ResultStatus, reason: String? = nil) -> BackendResult {
        BackendResult(status: status, reason: reason, kind: nil, vgid: nil, efiPartUuid: nil)
    }

    func testSuccessAndCleanExitIsTheOnlyWayToRecoveryWalkthrough() {
        let step = InstallFlowViewModel.terminalStep(exitCode: 0, result: result(.success))
        XCTAssertEqual(step, .recoveryWalkthrough)
    }

    func testExitZeroWithoutAResultIsFailureNotSuccess() {
        // The regression itself: pre-fix, this exact combination advanced.
        let step = InstallFlowViewModel.terminalStep(exitCode: 0, result: nil)
        guard case .failed(let msg) = step else {
            return XCTFail("exit 0 with no result must be .failed, got \(step)")
        }
        XCTAssertTrue(msg.contains("without reporting a result"))
    }

    func testAbortedExitsZeroButMustNotAdvance() {
        // `aborted` is exit 0 by design (user left the flow cleanly), so it is
        // indistinguishable from success by exit code alone.
        let step = InstallFlowViewModel.terminalStep(
            exitCode: 0, result: result(.aborted, reason: "left the menu"))
        guard case .failed(let msg) = step else {
            return XCTFail("aborted must be .failed, got \(step)")
        }
        XCTAssertTrue(msg.contains("left the menu"))
    }

    func testSuccessResultWithNonZeroExitDoesNotAdvance() {
        // A crash after the backend reported success.
        let step = InstallFlowViewModel.terminalStep(exitCode: 1, result: result(.success))
        guard case .failed(let msg) = step else {
            return XCTFail("success + nonzero exit must be .failed, got \(step)")
        }
        XCTAssertTrue(msg.contains("not advancing"))
    }

    func testFailureSurfacesTheBackendReason() {
        let step = InstallFlowViewModel.terminalStep(
            exitCode: 1, result: result(.failure, reason: "command failed: diskutil apfs foo"))
        guard case .failed(let msg) = step else {
            return XCTFail("expected .failed, got \(step)")
        }
        XCTAssertTrue(msg.contains("diskutil apfs foo"),
                      "the operator needs the backend's actual reason, not a generic message")
    }

    func testResultEventDecodesFromTheWireFormat() throws {
        let line = #"{"event":"result","status":"success","vgid":"VG-1","efiPartUuid":"aabbccdd"}"#
        let event = try JSONDecoder().decode(BackendEvent.self, from: Data(line.utf8))
        guard case .result(let r) = event else {
            return XCTFail("expected .result, got \(event)")
        }
        XCTAssertEqual(r.status, .success)
        // The PARTUUID is load-bearing for the install-config handoff, not decoration.
        XCTAssertEqual(r.efiPartUuid, "aabbccdd")
    }

    func testFailureResultDecodesWithKindAndReason() throws {
        let line = #"{"event":"result","status":"failure","reason":"boom","kind":"process"}"#
        let event = try JSONDecoder().decode(BackendEvent.self, from: Data(line.utf8))
        guard case .result(let r) = event else {
            return XCTFail("expected .result, got \(event)")
        }
        XCTAssertEqual(r.status, .failure)
        XCTAssertEqual(r.kind, "process")
        XCTAssertNil(r.efiPartUuid)
    }
}

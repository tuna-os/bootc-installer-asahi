import XCTest
@testable import Bootsahi

/// The process can exit before its stdout pipe reaches EOF. Termination must
/// therefore be gated on both signals so the final JSON result is delivered
/// before InstallFlowViewModel decides whether recoveryOS is safe to show.
final class InstallerProcessTests: XCTestCase {
    func testTerminationRequiresBothProcessExitAndStdoutEOF() {
        XCTAssertFalse(InstallerProcess.canNotifyTermination(status: nil, stdoutEOF: true, didNotify: false))
        XCTAssertFalse(InstallerProcess.canNotifyTermination(status: 0, stdoutEOF: false, didNotify: false))
        XCTAssertTrue(InstallerProcess.canNotifyTermination(status: 0, stdoutEOF: true, didNotify: false))
        XCTAssertFalse(InstallerProcess.canNotifyTermination(status: 0, stdoutEOF: true, didNotify: true))
    }
}

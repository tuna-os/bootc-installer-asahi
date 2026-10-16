import XCTest
@testable import Bootsahi

final class HardwareGateTests: XCTestCase {
    func testKnownUnsupportedGenerationsAreRefused() {
        if case .unsupported = HardwareGate.classify(model: "Mac15,3") { } else {
            XCTFail("M3-era model must be refused")
        }
        if case .unsupported = HardwareGate.classify(model: "Mac16,1") { } else {
            XCTFail("M4-era model must be refused")
        }
    }

    func testM1AndM2FamiliesRemainSupported() {
        if case .supported = HardwareGate.classify(model: "Mac14,2") { } else {
            XCTFail("M2 model should be supported")
        }
        if case .supported = HardwareGate.classify(model: "MacBookPro17,1") { } else {
            XCTFail("M1 model should be supported")
        }
    }
}

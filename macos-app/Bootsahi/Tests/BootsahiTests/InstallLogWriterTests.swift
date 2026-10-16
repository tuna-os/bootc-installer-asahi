import XCTest
@testable import Bootsahi

final class InstallLogWriterTests: XCTestCase {
    func testAppendedMessagesArePersistedToDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootsahi-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try InstallLogWriter(directory: root)
        writer.append(level: .progress, text: "partitioning disk")
        writer.append(level: .error, text: "backend crashed")
        writer.appendTermination(exitCode: 1)

        let contents = try String(contentsOf: root.appendingPathComponent("install.log"), encoding: .utf8)
        XCTAssertTrue(contents.contains("[progress] partitioning disk"))
        XCTAssertTrue(contents.contains("[error] backend crashed"))
        XCTAssertTrue(contents.contains("=== backend exited with code 1 ==="))
    }

    func testReopeningAnExistingLogAppendsRatherThanTruncates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootsahi-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try InstallLogWriter(directory: root).append(level: .info, text: "first run")
        try InstallLogWriter(directory: root).append(level: .info, text: "second run")

        let contents = try String(contentsOf: root.appendingPathComponent("install.log"), encoding: .utf8)
        XCTAssertTrue(contents.contains("first run"))
        XCTAssertTrue(contents.contains("second run"))
    }
}

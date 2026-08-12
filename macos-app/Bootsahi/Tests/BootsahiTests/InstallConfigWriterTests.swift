import XCTest
@testable import Bootsahi

final class InstallConfigWriterTests: XCTestCase {
    func testWritesAgentConfigUnderAsahiDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootsahi-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = InstallConfig(
            targetImgref: "ghcr.io/tuna-os/bonito:gnome-asahi",
            rootPartition: nil,
            espPartition: nil,
            filesystem: "btrfs",
            hostname: "test-mac",
            encryption: .init(type: "none"),
            user: .init(username: "alice", fullname: "Alice", password: "$6$hash", groups: ["wheel"]),
            wifi: .init(ssid: "test-network"),
            sshEnabled: false,
            cosignIdentity: "https://github.com/tuna-os/bonito/.github/workflows/build.yml@refs/heads/main",
            cosignIssuer: "https://token.actions.githubusercontent.com")

        try InstallConfigWriter.write(config, to: root)
        let path = root.appendingPathComponent("asahi/install-config.json")
        let data = try Data(contentsOf: path)
        let decoded = try JSONDecoder().decode(InstallConfig.self, from: data)
        XCTAssertEqual(decoded.targetImgref, config.targetImgref)
        XCTAssertEqual(decoded.user?.password, "$6$hash")
        XCTAssertEqual(decoded.wifi?.ssid, "test-network")
    }
}

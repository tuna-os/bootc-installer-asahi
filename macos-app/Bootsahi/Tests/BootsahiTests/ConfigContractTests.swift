import XCTest
@testable import Bootsahi

/// The D4 -> D1 contract: install-config.json is the ONLY thing joining this
/// app to the Linux first-boot agent.
///
/// InstallConfig.swift says "keep the two schemas in sync by hand; there's no
/// shared codegen". Hand-sync between two languages in one repo fails the same
/// way it does across repos — silently, with both test suites green, because
/// nothing reads both sides. The Swift suite proves the app compiles and the
/// bash suite proves the agent parses, and neither notices they have stopped
/// agreeing about what a config IS.
///
/// This has already cost us once, in the direction the type system cannot see:
/// the app offered "Encrypt with LUKS" and emitted encryption.type =
/// "luks-passphrase", a value the agent refuses outright (#20). Both suites
/// stayed green. The user would have found out at first boot — after their Mac
/// was repartitioned and the payload written, on the far side of the
/// destructive step.
///
/// So these tests read the AGENT'S OWN SCHEMA off disk rather than restating
/// its rules here. Restating them would just create a third copy to drift.
@MainActor
final class ConfigContractTests: XCTestCase {

    /// The agent's schema, loaded from the parent repo at test time.
    private func agentSchema() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        // ConfigContractTests.swift -> BootsahiTests -> Tests -> Bootsahi
        // -> macos-app -> repo root
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("components/bootsahi-agent")
            .appendingPathComponent("install-config.schema.json")
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("schema is not a JSON object")
            return [:]
        }
        return obj
    }

    /// A config with every optional field populated, so the key comparison
    /// below sees the app's FULL vocabulary rather than whichever subset a
    /// given screen happens to fill in.
    private func maximalConfig() -> InstallConfig {
        InstallConfig(
            targetImgref: "ghcr.io/tuna-os/bonito:gnome-asahi",
            rootPartition: "/dev/nvme0n1p5",
            espPartition: "/dev/nvme0n1p4",
            filesystem: "ext4",
            hostname: "bootsahi",
            encryption: .init(type: "none"),
            user: .init(username: "j", fullname: "J", password: "$6$abc", groups: ["wheel"]),
            wifi: .init(ssid: "home"),
            sshEnabled: true,
            cosignIdentity: "https://github.com/tuna-os/...",
            cosignIssuer: "https://token.actions.githubusercontent.com"
        )
    }

    private func encodedKeys(_ config: InstallConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Anything the app emits that the agent's schema does not declare is a
    /// field the agent will ignore. Silent ignoring is the dangerous shape: the
    /// app believes it communicated a choice and the install proceeds as though
    /// the user never made it.
    func testEveryEmittedKeyIsDeclaredByTheAgentSchema() throws {
        let schema = try agentSchema()
        let declared = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
        let emitted = Set(try encodedKeys(maximalConfig()).keys)

        let unknown = emitted.subtracting(declared).sorted()
        XCTAssertTrue(
            unknown.isEmpty,
            "app emits key(s) the agent does not declare and will silently "
                + "ignore: \(unknown). Add them to install-config.schema.json "
                + "and teach the agent to read them, or stop emitting them.")
    }

    /// The converse: a required key the app never sends is an install the agent
    /// refuses. Better here than on the user's Mac.
    func testEveryRequiredSchemaKeyIsEmitted() throws {
        let schema = try agentSchema()
        let required = Set(schema["required"] as? [String] ?? [])
        let emitted = Set(try encodedKeys(maximalConfig()).keys)

        let missing = required.subtracting(emitted).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "agent requires key(s) this app never emits: \(missing). The agent "
                + "will refuse the config and the install fails at first boot.")
    }

    /// encryption.type must be a value the schema's enum admits. Note this is
    /// weaker than what the agent enforces — the agent refuses every value
    /// except "none", because fisherman's customMounts path never runs
    /// luksFormat (#20). Asserting the enum is still worth doing: it catches a
    /// typo'd or invented type, and it will keep holding when LUKS lands and
    /// the agent's refusal is lifted.
    func testEncryptionTypeIsAValueTheSchemaAdmits() throws {
        let schema = try agentSchema()
        let props = schema["properties"] as? [String: Any] ?? [:]
        let enc = props["encryption"] as? [String: Any] ?? [:]
        let encProps = enc["properties"] as? [String: Any] ?? [:]
        let typeSpec = encProps["type"] as? [String: Any] ?? [:]
        let allowed = Set(typeSpec["enum"] as? [String] ?? [])
        XCTAssertFalse(allowed.isEmpty, "schema lost its encryption.type enum")

        let emitted = try encodedKeys(maximalConfig())
        let encryption = emitted["encryption"] as? [String: Any] ?? [:]
        let type = try XCTUnwrap(encryption["type"] as? String)
        XCTAssertTrue(
            allowed.contains(type),
            "encryption.type '\(type)' is not in the schema enum \(allowed.sorted())")
    }

    /// The secret channel is closed by the TYPE, not by the screens.
    ///
    /// #21 removed `psk` and `passphrase` from the model so no code path could
    /// populate them. This proves the removal actually holds under round-trip:
    /// a config decoded from JSON that DOES carry secrets must not carry them
    /// back out. That is the realistic reintroduction — not someone re-adding
    /// the field on purpose, but a decode of an older or hostile config
    /// laundering the secret back into a file we then write to the ESP, which
    /// is unencrypted, world-readable, and deliberately retained after a
    /// failed install.
    func testSecretsCannotSurviveARoundTripThroughTheModel() throws {
        let hostile = """
        {
          "targetImgref": "ghcr.io/tuna-os/bonito:gnome-asahi",
          "rootPartition": "/dev/nvme0n1p5",
          "espPartition": "/dev/nvme0n1p4",
          "filesystem": "ext4",
          "hostname": "bootsahi",
          "encryption": {"type": "none", "passphrase": "hunter2"},
          "wifi": {"ssid": "home", "psk": "hunter2"},
          "cosignIdentity": "x",
          "cosignIssuer": "y"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InstallConfig.self, from: hostile)
        let reencoded = try JSONEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: reencoded, encoding: .utf8))

        // Assert on the secret VALUE, not just the key names: a renamed field
        // that still carries "hunter2" to the ESP is the same disclosure.
        XCTAssertFalse(
            text.contains("hunter2"),
            "a secret survived a decode/encode round trip and would be written "
                + "to the world-readable ESP: \(text)")
        XCTAssertFalse(text.contains("psk"), "wifi.psk reappeared in the model")
        XCTAssertFalse(
            text.contains("passphrase"), "encryption.passphrase reappeared in the model")
    }

    /// The schema pins `additionalProperties: false` on the two objects that
    /// carry secrets in every naive design. If that ever relaxes, the agent
    /// stops being able to tell "SSID only" from "SSID plus PSK" — and the
    /// refusal that protects the user becomes unenforceable at the schema
    /// layer. Cheap to assert, and it fails loudly at the moment of relaxation
    /// rather than at the moment of exploitation.
    func testSecretBearingObjectsStayClosedInTheSchema() throws {
        let schema = try agentSchema()
        let props = schema["properties"] as? [String: Any] ?? [:]
        for name in ["wifi", "encryption"] {
            let obj = props[name] as? [String: Any] ?? [:]
            XCTAssertEqual(
                obj["additionalProperties"] as? Bool, false,
                "\(name) no longer forbids additional properties — an unknown "
                    + "key (a PSK, a passphrase) would now validate")
        }
    }
}

import Foundation

/// Mirrors components/bootsahi-agent/install-config.schema.json in the
/// parent repo — Bootsahi writes this file to the ESP as
/// `<ESP>/bootsahi/install-config.json` for the D1 first-boot agent to
/// consume. Keep the two schemas in sync by hand; there's no shared codegen
/// between this Swift model and the JSON Schema (yet).
struct InstallConfig: Codable {
    var targetImgref: String
    var rootPartition: String
    var espPartition: String
    var filesystem: String // "xfs" | "ext4" | "btrfs"
    var hostname: String
    var encryption: Encryption?
    var user: UserSpec?
    var wifi: WifiCreds?
    var sshEnabled: Bool?
    var cosignIdentity: String?
    var cosignIssuer: String?

    /// Type only. Like the Wi-Fi passphrase, a LUKS passphrase is asked for at
    /// first boot in Linux and never written to the ESP — storing the unlock
    /// secret in the clear beside the volume it unlocks would defeat the point
    /// of encrypting it (issue #21). The agent refuses a config carrying one.
    struct Encryption: Codable {
        var type: String // "none" | "luks-passphrase" | "tpm2-luks" | "tpm2-luks-passphrase"
    }

    struct UserSpec: Codable {
        var username: String
        var fullname: String?
        /// MUST be a crypt hash (`$6$…`) by the time it is written to the ESP —
        /// bootsahi-agent refuses a config whose password is not already
        /// hashed, and will not install (issue #21).
        ///
        /// It currently holds the password as typed, which is fine only
        /// because `writeInstallConfig()` is still a TODO and nothing reaches
        /// the ESP yet. Whoever implements that write is the one who has to
        /// hash it — the ESP is unencrypted, world-readable FAT that persists
        /// across a failed install, and users reuse passwords.
        ///
        /// `openssl passwd -6` is available on macOS and produces the right
        /// form; fisherman applies a `$`-prefixed value verbatim via
        /// `chpasswd -e`, matching what wootc already does on Windows.
        var password: String
        var groups: [String]?
    }

    /// SSID only, deliberately. The passphrase is asked for on the Mac's
    /// behalf at *first boot in Linux*, by bootsahi-agent via
    /// systemd-ask-password — it is never written to the ESP, and the agent
    /// refuses a config that contains one (issue #21).
    ///
    /// Encrypting it here would not have helped: any key the agent could use
    /// unattended would have to live on the same disk an attacker already
    /// holds, so it would move the secret rather than protect it.
    struct WifiCreds: Codable {
        var ssid: String
    }
}

/// One entry in catalog.json — generated in CI from registry-map.yaml per
/// DESIGN.md's "Catalog = the registries" principle. Schema is Bootsahi's
/// own invention (no CI generation exists yet); adjust once that job lands.
struct CatalogEntry: Codable, Identifiable, Hashable {
    var id: String { imgref }
    var variant: String     // e.g. "bonito"
    var desktop: String     // e.g. "gnome"
    var stream: String      // e.g. "stable"
    var imgref: String       // e.g. "ghcr.io/tuna-os/bonito:gnome-asahi"
    var description: String
}

struct Catalog: Codable {
    var generatedAt: String
    var entries: [CatalogEntry]
}

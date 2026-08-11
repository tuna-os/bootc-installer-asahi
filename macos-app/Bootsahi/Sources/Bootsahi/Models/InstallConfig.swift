import Foundation

/// Mirrors components/bootsahi-agent/install-config.schema.json in the
/// parent repo — Bootsahi writes this file to the ESP as
/// `<ESP>/bootsahi/install-config.json` for the D1 first-boot agent to
/// consume. Keep the two schemas in sync by hand; there's no shared codegen
/// between this Swift model and the JSON Schema (yet).
struct InstallConfig: Codable {
    var targetImgref: String
    /// DEV/TEST OVERRIDE ONLY. The agent resolves the install target at runtime
    /// from the backend-recorded PARTUUID in stub_info.json (issue #22). The macOS
    /// app cannot produce a correct Linux device name — it knows the partition as
    /// "disk0s5" while Linux sees "nvme0n1p5" — so production should omit this
    /// field entirely. A config without it succeeds only when stub_info.json is
    /// present at first boot.
    var rootPartition: String?
    /// DEV/TEST OVERRIDE ONLY. Same status as rootPartition.
    var espPartition: String?
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
        /// A `$6$` SHA-512 crypt hash, never the password as typed.
        ///
        /// OptionsView hashes it with `PasswordHash.hash(_:)` before it reaches
        /// this struct, so plaintext never lives on the view model at all. That
        /// matters because this file is written to the EFI system partition:
        /// unencrypted FAT, world-readable, and deliberately retained after a
        /// failed install so the run can be retried.
        ///
        /// bootsahi-agent refuses a config whose password is not already hashed
        /// (issue #21), and fisherman applies a `$`-prefixed value verbatim via
        /// `chpasswd -e`, matching what wootc does on Windows.
        ///
        /// An earlier version of this comment suggested `openssl passwd -6` for
        /// the hashing. Do not: macOS ships LibreSSL, whose `passwd` subcommand
        /// does not offer `-6`, and Darwin's `crypt(3)` does not implement `$6$`
        /// either. `PasswordHash` exists precisely because neither system tool
        /// can be relied on.
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
    /// cosign certificate-identity (REQUIRED — the agent refuses a config
    /// without it, and this struct is the only producer of such configs).
    /// See issue #24.
    var cosignIdentity: String
    /// cosign OIDC issuer, paired with cosignIdentity (REQUIRED — a
    /// half-policy is refused exactly like a missing one).
    var cosignIssuer: String
}

struct Catalog: Codable {
    var generatedAt: String
    var entries: [CatalogEntry]
}

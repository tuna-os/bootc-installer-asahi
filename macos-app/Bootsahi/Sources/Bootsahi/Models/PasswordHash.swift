import Foundation
import CryptoKit

/// SHA-512 crypt (`$6$…`), the hash format Linux `shadow` expects.
///
/// **Why this exists at all.** `install-config.json` is written to the EFI
/// system partition: unencrypted FAT, world-readable, and deliberately RETAINED
/// after a failed install so the run can be retried. A password sitting there in
/// the clear is readable by anyone who picks the Mac up, and people reuse
/// passwords — so the exposure is not limited to this machine. bootsahi-agent
/// therefore refuses a config whose password is not already hashed (#21), which
/// means an unhashed password is not merely unsafe, it is an install that fails
/// at first boot after the disk has been repartitioned.
///
/// **Why hand-rolled rather than shelling out.** The obvious move is
/// `openssl passwd -6`, and `InstallConfig.swift` assumed it was available. It
/// is not dependable: macOS ships LibreSSL, whose `passwd` subcommand does not
/// offer `-6` across the versions in the supported range. `crypt(3)` on Darwin
/// does not implement `$6$` either. Depending on either would mean an installer
/// that works on the developer's Mac and silently produces an unusable account
/// on someone else's — discovered at the login prompt, after the install.
///
/// **Why hand-rolled crypto is acceptable here specifically.** This is not a
/// novel scheme; it is a fully specified one (Drepper's SHA-crypt) with a hard
/// external oracle. The implementation was prototyped and checked byte-for-byte
/// against both `openssl passwd -6` and Python's `crypt` before being written,
/// and `PasswordHashTests` pins those vectors — including the empty password and
/// a password longer than the 64-byte digest, which are the cases that exercise
/// the awkward loop branches. A wrong implementation cannot pass quietly.
enum PasswordHash {

    /// crypt(3)'s base64 alphabet, which is NOT RFC 4648: the ordering differs
    /// and it emits least-significant group first.
    private static let alphabet = Array(
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// The byte interleave the SHA-512 variant uses when encoding the final
    /// digest. It is not a rotation or any other pattern that could be
    /// generated — it is a table, and it is simply copied from the spec.
    private static let permutation: [(Int, Int, Int)] = [
        (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
        (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
        (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
        (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
        (62, 20, 41),
    ]

    static let defaultRounds = 5000

    /// Produces a `$6$<salt>$<hash>` string.
    ///
    /// `salt` is truncated to 16 characters, as the spec requires — silently,
    /// because that is what every other implementation does and diverging would
    /// produce hashes no `shadow` could verify.
    static func sha512Crypt(
        password: String,
        salt: String,
        rounds: Int = defaultRounds
    ) -> String {
        let pw = Array(password.utf8)
        let saltBytes = Array(salt.utf8.prefix(16))

        // B: digest of password + salt + password.
        let b = digest(pw + saltBytes + pw)

        // A: password + salt, then B mixed in by length, then by the bits of
        // the length. The two loops below look redundant and are not.
        var aInput = pw + saltBytes
        var cnt = pw.count
        while cnt > 64 {
            aInput += b
            cnt -= 64
        }
        aInput += b.prefix(cnt)

        cnt = pw.count
        while cnt > 0 {
            aInput += (cnt & 1) == 1 ? b : pw
            cnt >>= 1
        }
        let a = digest(aInput)

        // P: the password sequence, stretched to the password's length.
        var dpInput: [UInt8] = []
        for _ in 0..<pw.count { dpInput += pw }
        let p = stretch(digest(dpInput), to: pw.count)

        // S: the salt sequence, stretched to the salt's length. The repeat
        // count depends on the first byte of A, which is what makes the work
        // input-dependent.
        var dsInput: [UInt8] = []
        for _ in 0..<(16 + Int(a[0])) { dsInput += saltBytes }
        let s = stretch(digest(dsInput), to: saltBytes.count)

        // The deliberately slow part.
        var c = a
        for i in 0..<rounds {
            var input: [UInt8] = []
            input += (i & 1) == 1 ? p : c
            if i % 3 != 0 { input += s }
            if i % 7 != 0 { input += p }
            input += (i & 1) == 1 ? c : p
            c = digest(input)
        }

        let prefix = rounds == defaultRounds ? "$6$" : "$6$rounds=\(rounds)$"
        return prefix + String(decoding: saltBytes, as: UTF8.self) + "$" + encode(c)
    }

    /// Hashes with a fresh random salt. This is the call sites should use;
    /// `sha512Crypt(password:salt:)` exists so tests can pin known vectors.
    static func hash(_ password: String) -> String {
        sha512Crypt(password: password, salt: randomSalt())
    }

    /// 16 characters from crypt's alphabet.
    ///
    /// `SystemRandomNumberGenerator` is the platform CSPRNG on Apple platforms,
    /// which is the bar a salt needs to clear — a salt must be unpredictable and
    /// unique, not secret.
    static func randomSalt(length: Int = 16) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            alphabet[Int(rng.next(upperBound: UInt64(alphabet.count)))]
        })
    }

    /// True when a value is already a crypt hash and must be passed through
    /// rather than hashed again. fisherman keys off the same `$` prefix to
    /// decide between `chpasswd` and `chpasswd -e`.
    static func isCryptHash(_ value: String) -> Bool {
        value.hasPrefix("$")
    }

    // MARK: - Internals

    private static func digest(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA512.hash(data: Data(bytes)))
    }

    private static func stretch(_ seed: [UInt8], to length: Int) -> [UInt8] {
        guard length > 0 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while out.count < length {
            out += seed.prefix(min(seed.count, length - out.count))
        }
        return out
    }

    private static func encode(_ c: [UInt8]) -> String {
        var out: [Character] = []
        out.reserveCapacity(86)
        for (b2, b1, b0) in permutation {
            var w = (Int(c[b2]) << 16) | (Int(c[b1]) << 8) | Int(c[b0])
            for _ in 0..<4 {
                out.append(alphabet[w & 0x3f])
                w >>= 6
            }
        }
        // The final group is the last byte alone, two characters.
        var w = Int(c[63])
        for _ in 0..<2 {
            out.append(alphabet[w & 0x3f])
            w >>= 6
        }
        return String(out)
    }
}

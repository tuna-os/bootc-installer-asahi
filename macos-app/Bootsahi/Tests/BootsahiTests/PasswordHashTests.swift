import XCTest
@testable import Bootsahi

/// Pins `PasswordHash` against externally generated vectors.
///
/// Every `expected` value below was produced by BOTH `openssl passwd -6` and
/// Python's `crypt` module (which delegates to glibc), on Linux, and the two
/// agreed. None of them was written from memory — a remembered hash is a
/// plausible-looking string that would pin the implementation to whatever it
/// happens to do, which is the opposite of a test.
///
/// The stakes justify the paranoia: a subtly wrong `$6$` string is not a
/// visible failure. It is a syntactically valid hash that no password unlocks,
/// discovered by the user at the login prompt of a freshly installed machine,
/// after the Mac has been repartitioned.
final class PasswordHashTests: XCTestCase {

    private struct Vector {
        let password: String
        let salt: String
        let expected: String
    }

    /// Chosen for coverage of the branches, not for variety:
    /// - the two canonical vectors from the specification;
    /// - the EMPTY password, where both length-driven loops run zero times;
    /// - a single-character password, the minimal non-empty case;
    /// - a 70-byte password, which is the only case that drives the
    ///   `while cnt > 64` branch and the multi-block stretch of P;
    /// - an over-long salt, which must be truncated to 16;
    /// - non-ASCII, which fixes the answer to "bytes or characters?" — it is
    ///   UTF-8 bytes, and a Swift implementation indexing `String` by
    ///   character would pass every ASCII test and fail only for users whose
    ///   passwords are not English.
    private let vectors: [Vector] = [
        Vector(password: "Hello world!", salt: "saltstring",
               expected: "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"),
        Vector(password: "This is just a test", salt: "toolongsaltstring",
               expected: "$6$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0"),
        Vector(password: "", salt: "abc",
               expected: "$6$abc$mJP3a6FyA8uCnzRtlnNypPwjnvpi5TP9qOrInzrfDmwxUQG38PkpCPdqfTb8JQfAngapMxeim4AZ..hSdRRzD."),
        Vector(password: "a", salt: "xy",
               expected: "$6$xy$5250cwD6G0HaskWEVps7HLt3iuI6RaW0CtpUDWt4NW09jSLinak2eYcP4KwS5.Qo0wBM5cNC2oN8ZPa0MGMfh1"),
        Vector(password: String(repeating: "p", count: 70), salt: "0123456789abcdef",
               expected: "$6$0123456789abcdef$pHTHI0DhqCkYIa87Afq4cVoQ1bEjhrsIYHYwdJkQU2O6RAsuSAaHBH7H5NIg8mH5EdSXyonSK2JJ0Vr.1GYGU0"),
        Vector(password: "correct horse battery staple", salt: "Zm9vYmFyYmF6cXV4",
               expected: "$6$Zm9vYmFyYmF6cXV4$DzHRPsRdoHbBTgRAhGoicBjHoMhJVDTvClX09.mtQfgpfAoXyTwCxY.TEK3BS0gXdCaLYl/L42PBrPFfY6EXq1"),
        Vector(password: "ünïcödé pässwörd", salt: "saltsalt",
               expected: "$6$saltsalt$/Yd9dKWXXTygvnu2/8xQUuIkdUBnoBxhM2x7DB02lkY.5pdEA912WFPfUWN3LiEwEMzvBOx7tGc5vWyL7f0Ar/"),
    ]

    func testMatchesGlibcAndOpenSSL() {
        for v in vectors {
            XCTAssertEqual(
                PasswordHash.sha512Crypt(password: v.password, salt: v.salt),
                v.expected,
                "sha512Crypt disagrees with glibc for password of length "
                    + "\(v.password.utf8.count) and salt '\(v.salt)'")
        }
    }

    /// The shape `shadow` and fisherman both parse: `$6$<=16 salt$86 chars`.
    func testOutputShape() {
        let hash = PasswordHash.hash("hunter2")
        XCTAssertTrue(hash.hasPrefix("$6$"), "missing the SHA-512 crypt id")
        let fields = hash.split(separator: "$", omittingEmptySubsequences: true)
        XCTAssertEqual(fields.count, 3, "expected id/salt/hash, got \(hash)")
        XCTAssertLessThanOrEqual(fields[1].count, 16, "salt longer than the spec allows")
        XCTAssertEqual(fields[2].count, 86, "a SHA-512 crypt digest is 86 characters")
    }

    /// Two hashes of the same password must differ. If they did not, the salt
    /// would not be random, and the ESP — which keeps this file after a failed
    /// install — would leak that two machines share a password.
    func testSaltIsRandomPerCall() {
        let a = PasswordHash.hash("same password")
        let b = PasswordHash.hash("same password")
        XCTAssertNotEqual(a, b, "salt is not random; hashes are deterministic")
    }

    /// Guards the pass-through rule. Re-hashing an already-hashed value yields
    /// a hash of the hash — a valid-looking string that no password unlocks.
    func testAlreadyHashedValuesAreRecognised() {
        XCTAssertTrue(PasswordHash.isCryptHash("$6$abc$def"))
        XCTAssertTrue(PasswordHash.isCryptHash("$y$j9T$salt$hash"))
        XCTAssertFalse(PasswordHash.isCryptHash("hunter2"))
        XCTAssertFalse(PasswordHash.isCryptHash(""))
    }
}

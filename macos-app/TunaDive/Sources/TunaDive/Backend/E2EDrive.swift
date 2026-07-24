import Foundation

/// Drive-mode E2E seam, mirroring wootc's (`app/app.go`'s
/// `E2EDriveDirective`/`E2EDriveReport`, see tuna-dive-agent#6 §2). wootc
/// needed this because wails' WebView2 loader ignores the CDP debug-port
/// env var, making Chrome-DevTools-style automation impossible — the fix
/// was to drive the real UI through the same bridge every user click
/// crosses instead of a UI-automation framework. SwiftUI has no browser to
/// automate either way, but the same shape (poll a directive file, apply it
/// directly to the live ViewModel, write state back) gets CI-testable
/// coverage of the exact code path a real click takes, with no
/// accessibility-automation dependency (fragile and slow on macOS CI).
///
/// UNVERIFIED — this is a first draft of the directive shape, not proven
/// against a real harness (wootc's own harness is Go/JS; nothing analogous
/// exists on the Asahi side yet). Inert unless TUNADIVE_E2E_DRIVE=1.
enum E2EDrive {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TUNADIVE_E2E_DRIVE"] == "1"
    }

    private static let directivePath = "/tmp/tuna-dive-e2e-drive.json"
    private static let statePath = "/tmp/tuna-dive-e2e-drive-state.json"

    enum Directive: Decodable {
        case selectCatalogEntry(imgref: String)
        case setHostname(String)
        case advance
        case answerAsk(JSONValue?)

        private enum CodingKeys: String, CodingKey { case action, imgref, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .action) {
            case "selectCatalogEntry":
                self = .selectCatalogEntry(imgref: try c.decode(String.self, forKey: .imgref))
            case "setHostname":
                self = .setHostname(try c.decode(String.self, forKey: .value))
            case "advance":
                self = .advance
            case "answerAsk":
                self = .answerAsk(try c.decodeIfPresent(JSONValue.self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .action, in: c, debugDescription: "unknown drive directive")
            }
        }
    }

    /// Reads and consumes (deletes) the pending directive, or nil if drive
    /// mode is off or none is queued. Consuming on read avoids re-applying
    /// the same directive on the next poll tick.
    static func nextDirective() -> Directive? {
        guard isEnabled, let data = try? Data(contentsOf: URL(fileURLWithPath: directivePath)) else {
            return nil
        }
        try? FileManager.default.removeItem(atPath: directivePath)
        return try? JSONDecoder().decode(Directive.self, from: data)
    }

    /// Persists the harness-visible state snapshot. Call after every
    /// directive is applied, same as wootc's frontend calls E2EDriveReport
    /// after every state change.
    static func report(_ state: [String: Any]) {
        guard isEnabled, let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }
}

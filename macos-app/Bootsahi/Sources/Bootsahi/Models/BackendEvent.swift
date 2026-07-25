import Foundation

/// Mirrors the `--json` protocol documented in asahi-installer's
/// docs/json-mode.md (hanthor/asahi-installer@json-machine-mode). Keep this
/// file in sync with that doc — it is the source of truth, not this file.
enum MessageLevel: String, Codable {
    case plain, info, progress, message, error, warning, question, success, prompt, choice
}

struct BackendMessage: Decodable {
    let level: MessageLevel
    let text: String
}

enum AskKind: String, Codable {
    case input
    case password
    case continueAck = "continue"
    case yesno
    case choice
    case size
}

struct BackendAsk: Decodable {
    let kind: AskKind
    let id: String
    let prompt: String
    let defaultValue: JSONValue?
    let options: [String: String]?
    /// Byte counts, only present for kind == .size — see json-mode.md's note
    /// on why `size` carries raw numbers instead of a formatted string.
    let min: Int64?
    let max: Int64?
    let total: Int64?

    enum CodingKeys: String, CodingKey {
        case kind, id, prompt
        case defaultValue = "default"
        case options, min, max, total
    }
}

/// Terminal status from the backend's single `result` event.
enum ResultStatus: String, Codable {
    case success
    case failure
    /// The user left the installer flow cleanly without installing. Exits 0,
    /// so it is indistinguishable from success by exit code alone — which is
    /// exactly why this event exists.
    case aborted
}

/// The one terminal event per backend run. See json-mode.md: a driver must
/// require BOTH `status == .success` and a clean exit, and must treat the
/// absence of this event as failure rather than as "still running".
struct BackendResult: Decodable {
    let status: ResultStatus
    let reason: String?
    /// `process`, `exception`, `interrupted`, or `internal`; failures only.
    let kind: String?
    let vgid: String?
    /// GPT PARTUUID of the ESP the backend created. The only place this is
    /// knowable, and what the first-boot agent needs to identify the ESP
    /// without a device node (macOS: disk0sN, Linux: nvme0n1pN).
    let efiPartUuid: String?
}

enum BackendEvent: Decodable {
    case message(BackendMessage)
    case ask(BackendAsk)
    case result(BackendResult)

    private enum RootKeys: String, CodingKey { case event }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        switch event {
        case "message":
            self = .message(try BackendMessage(from: decoder))
        case "ask":
            self = .ask(try BackendAsk(from: decoder))
        case "result":
            self = .result(try BackendResult(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container,
                debugDescription: "unknown event kind '\(event)'")
        }
    }
}

/// The one line Bootsahi writes back per outstanding ask.
struct BackendAnswer: Encodable {
    let id: String
    let value: JSONValue?
}

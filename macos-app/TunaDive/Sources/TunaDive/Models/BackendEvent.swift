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

enum BackendEvent: Decodable {
    case message(BackendMessage)
    case ask(BackendAsk)

    private enum RootKeys: String, CodingKey { case event }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        switch event {
        case "message":
            self = .message(try BackendMessage(from: decoder))
        case "ask":
            self = .ask(try BackendAsk(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container,
                debugDescription: "unknown event kind '\(event)'")
        }
    }
}

/// The one line TunaDive writes back per outstanding ask.
struct BackendAnswer: Encodable {
    let id: String
    let value: JSONValue?
}

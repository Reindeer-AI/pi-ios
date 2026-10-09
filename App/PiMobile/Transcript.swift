import Foundation

/// One rendered transcript row. Built from the engine's `session.transcript` items and from committed entries in live
/// agent events (an entry keeps its model-facing message in `model[0]`).
enum TranscriptItem: Identifiable, Equatable {
    case user(id: Int, text: String)
    case assistant(id: Int, text: String, thinking: String, toolCalls: [ToolCall], error: String?)
    case tool(id: Int, toolCallId: String, toolName: String, output: String, isError: Bool)
    /// A message an extension sent for the user to see (pi's `display: true`).
    case custom(id: Int, customType: String, text: String)
    /// A `!command` the user ran in the session's shell.
    case bash(id: Int, command: String, output: String, exitCode: Int?)
    /// Where pi compacted the context: the summary that replaced what came before, and why (`manual`, `threshold`,
    /// `overflow`).
    case compaction(id: Int, summary: String, reason: String)

    struct ToolCall: Equatable, Identifiable {
        let id: String
        let name: String
        let arguments: String
    }

    var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _, _, _, _), .tool(let id, _, _, _, _), .custom(let id, _, _), .bash(let id, _, _, _),
             .compaction(let id, _, _): id
        }
    }

    /// From an item of the engine's `session.transcript`.
    init?(item: [String: Any]) {
        let id = item["entryId"] as? Int ?? 0
        switch item["kind"] as? String {
        case "user":
            self = .user(id: id, text: item["text"] as? String ?? "")
        case "assistant":
            let calls = (item["toolCalls"] as? [[String: Any]] ?? []).map {
                ToolCall(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", arguments: $0["arguments"] as? String ?? "")
            }
            self = .assistant(id: id, text: item["text"] as? String ?? "", thinking: item["thinking"] as? String ?? "",
                              toolCalls: calls, error: item["error"] as? String)
        case "tool":
            self = .tool(id: id, toolCallId: item["toolCallId"] as? String ?? "", toolName: item["toolName"] as? String ?? "",
                         output: item["output"] as? String ?? "", isError: item["isError"] as? Bool ?? false)
        case "custom":
            self = .custom(id: id, customType: item["customType"] as? String ?? "", text: item["text"] as? String ?? "")
        case "bash":
            self = .bash(id: id, command: item["command"] as? String ?? "", output: item["output"] as? String ?? "",
                         exitCode: item["exitCode"] as? Int)
        case "compaction":
            self = .compaction(id: id, summary: item["summary"] as? String ?? "", reason: item["reason"] as? String ?? "")
        default:
            return nil
        }
    }

    /// From a committed entry in a `message_end` or `entry_appended` agent event.
    init?(entry: [String: Any]) {
        let id = entry["id"] as? Int ?? 0
        let data = entry["data"] as? [String: Any] ?? [:]
        if entry["kind"] as? String == "pimobile.bash" {
            self = .bash(id: id, command: data["command"] as? String ?? "", output: data["output"] as? String ?? "",
                         exitCode: data["exitCode"] as? Int)
            return
        }
        guard let message = (entry["model"] as? [[String: Any]])?.first else { return nil }
        let blocks = message["content"] as? [[String: Any]] ?? []
        switch entry["kind"] as? String {
        case "pimobile.custom-message":
            guard data["display"] as? Bool != false else { return nil }
            self = .custom(id: id, customType: data["customType"] as? String ?? "",
                           text: (message["content"] as? String) ?? Self.text(of: blocks))
        case "pi.user":
            self = .user(id: id, text: (message["content"] as? String) ?? Self.text(of: blocks))
        case "pi.assistant":
            let stopReason = message["stopReason"] as? String
            self = .assistant(
                id: id,
                text: Self.text(of: blocks),
                thinking: blocks.filter { $0["type"] as? String == "thinking" }.compactMap { $0["thinking"] as? String }.joined(),
                toolCalls: blocks.filter { $0["type"] as? String == "toolCall" }.map {
                    ToolCall(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", arguments: Self.arguments($0["arguments"]))
                },
                error: stopReason == "error" || stopReason == "aborted" ? (message["errorMessage"] as? String ?? stopReason) : nil
            )
        case "pi.tool-result":
            self = .tool(id: id, toolCallId: message["toolCallId"] as? String ?? "", toolName: message["toolName"] as? String ?? "",
                         output: Self.text(of: blocks), isError: message["isError"] as? Bool ?? false)
        case "pi.compaction":
            self = .compaction(id: id, summary: Self.summary(of: (message["content"] as? String) ?? Self.text(of: blocks)),
                               reason: data["reason"] as? String ?? "")
        default:
            return nil
        }
    }

    /// A compaction's summary, without the framing the model gets it in.
    static func summary(of text: String) -> String {
        guard let start = text.range(of: "<summary>"), let end = text.range(of: "</summary>", range: start.upperBound..<text.endIndex) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(of blocks: [[String: Any]]) -> String {
        blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    static func arguments(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The assistant message being streamed, by content index (pi-durable coalesces deltas per commit: a message's first
/// content can arrive in `message_start`, a block's first text in its `*_start` change).
struct DraftMessage: Equatable {
    struct Block: Equatable {
        enum Kind { case text, thinking, toolCall }
        var kind: Kind
        var text: String
    }

    var blocks: [Int: Block] = [:]

    var text: String { joined(.text) }
    var thinking: String { joined(.thinking) }

    init(message: [String: Any]) {
        for (index, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
            blocks[index] = Self.block(block)
        }
    }

    mutating func apply(_ change: [String: Any]) {
        let index = change["contentIndex"] as? Int ?? 0
        switch change["type"] as? String {
        case "text_start", "thinking_start", "toolcall_start", "block":
            blocks[index] = Self.block(change["block"] as? [String: Any] ?? [:])
        case "text_delta":
            blocks[index, default: Block(kind: .text, text: "")].text += change["delta"] as? String ?? ""
        case "thinking_delta":
            blocks[index, default: Block(kind: .thinking, text: "")].text += change["delta"] as? String ?? ""
        case "message":
            self = DraftMessage(message: change["message"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func joined(_ kind: Block.Kind) -> String {
        blocks.sorted { $0.key < $1.key }.map(\.value).filter { $0.kind == kind }.map(\.text).joined()
    }

    private static func block(_ block: [String: Any]) -> Block {
        switch block["type"] as? String {
        case "thinking": Block(kind: .thinking, text: block["thinking"] as? String ?? "")
        case "toolCall": Block(kind: .toolCall, text: block["name"] as? String ?? "")
        default: Block(kind: .text, text: block["text"] as? String ?? "")
        }
    }
}

/// A tool call that is still running, with its streamed output.
struct ToolRun: Equatable, Identifiable {
    let id: String
    let name: String
    let arguments: String
    var output = ""
}

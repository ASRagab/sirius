import Foundation
import SiriusCore
import SiriusProtocol

// The subset of Claude Code's stream-json the adapter speaks:
// one JSON object per line each way. In: a `user` message per turn. Out: a
// `system/init` at the start of every turn and a `result` at its end, both
// carrying `session_id`. Everything else passes through to the observer only.
enum ClaudeStream {
    enum Event: Equatable {
        // model: the id the turn runs on.
        case initialized(session: String?, model: String?)
        // turns: num_turns; 0 on the empty result Claude adds after a turn
        // it started by itself. messages: the uuids of the user lines the
        // turn took in (user_message_uuids), several when lines written
        // mid-turn joined it; [] on a turn Claude started by itself; nil from
        // a CLI that does not say (checked on 2.1.296).
        case result(session: String?, failure: String?, turns: Int? = nil, messages: [String]? = nil)
        // Our own user line, echoed back (--replay-user-messages) with the
        // uuid we gave it: the turn after it is ours.
        case replayed(uuid: String)
        // A main-thread model call's input: the context it ran on, in
        // tokens, cached or not. A subagent's (parent_tool_use_id set) is not.
        case context(tokens: Int)
        // A compaction finished (compact_boundary): the context's messages
        // in tokens before and after, and how long it took (CLI 2.1.311).
        case compacted(before: Int?, after: Int?, milliseconds: Int?)
        case other
    }

    static func decode(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    static func parse(_ line: Data) -> Event? {
        decode(line).flatMap { parse($0) }
    }

    static func parse(_ object: [String: Any]) -> Event? {
        guard let type = object["type"] as? String else { return nil }
        let session = object["session_id"] as? String
        switch type {
        case "system" where object["subtype"] as? String == "init":
            return .initialized(session: session, model: object["model"] as? String)
        case "system" where object["subtype"] as? String == "compact_boundary":
            let metadata = object["compact_metadata"] as? [String: Any] ?? [:]
            return .compacted(before: metadata["pre_tokens"] as? Int, after: metadata["post_tokens"] as? Int,
                              milliseconds: metadata["duration_ms"] as? Int)
        case "assistant" where object["parent_tool_use_id"] as? String == nil:
            guard let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] else { return .other }
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            return tokens > 0 ? .context(tokens: tokens) : .other
        case "result":
            var messages: [String]?
            if let uuids = object["user_message_uuids"] as? [String] {
                messages = uuids
            } else if object.keys.contains("user_message_uuid") {
                messages = [object["user_message_uuid"] as? String].compactMap { $0 }
            }
            return .result(session: session, failure: failure(of: object), turns: object["num_turns"] as? Int,
                           messages: messages)
        case "user" where object["isReplay"] as? Bool == true:
            guard let uuid = object["uuid"] as? String else { return .other }
            return .replayed(uuid: uuid)
        default:
            return .other
        }
    }

    // nil when the turn succeeded.
    private static func failure(of result: [String: Any]) -> String? {
        let subtype = result["subtype"] as? String
        let isError = result["is_error"] as? Bool ?? false
        guard isError || (subtype != nil && subtype != "success") else { return nil }
        if let errors = result["errors"] as? [String], !errors.isEmpty {
            return errors.joined(separator: "; ")
        }
        if let text = result["result"] as? String, !text.isEmpty {
            return text
        }
        return subtype ?? "error"
    }

    // The media types the Messages API takes as image blocks.
    static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    // The API's limit is 5 MB per image, base64 included: 3.75 MB raw.
    static let maxImageBytes = 3_750_000

    // One user turn: native image blocks for the image attachments that fit,
    // then the rendered wrapper, which names every attachment by path.
    static func userMessage(_ message: Message, uuid: String = UUID().uuidString.lowercased()) throws -> Data {
        var content: [[String: Any]] = []
        for attachment in message.attachments {
            if let block = imageBlock(attachment) { content.append(block) }
        }
        content.append(["type": "text", "text": MessageRenderer.render(message)])
        let line: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "message": ["role": "user", "content": content],
        ]
        var data = try JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    // A line of plain text, unwrapped, e.g. a slash command: Claude runs
    // "/compact <instructions>" sent this way and ends it with a result
    // naming the line's uuid (checked on 2.1.311).
    static func command(_ text: String, uuid: String = UUID().uuidString.lowercased()) throws -> Data {
        let line: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        var data = try JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func imageBlock(_ attachment: Message.Attachment) -> [String: Any]? {
        var type = attachment.mimeType.lowercased()
        if type == "image/jpg" { type = "image/jpeg" }
        guard imageTypes.contains(type) else { return nil }
        let url = URL(fileURLWithPath: attachment.path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size <= maxImageBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return [
            "type": "image",
            "source": ["type": "base64", "media_type": type, "data": data.base64EncodedString()],
        ]
    }
}

// Where `claude` is: the registration's executable when it runs, else PATH,
// else the usual install locations.
enum ClaudeLocator {
    static func locate(executable: String, environment: [String: String],
                       home: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        if !executable.isEmpty, fm.isExecutableFile(atPath: executable) { return executable }
        let path = environment["PATH"] ?? ""
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent("claude")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let common = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return common.first { fm.isExecutableFile(atPath: $0) }
    }
}

// The last few KB of the agent's stderr, for the failure reason.
final class ClaudeStderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let limit = 4096

    // stderr reached its end.
    func finish() {
        lock.withLock { finished = true }
    }

    // Waits up to `seconds` for the end of stderr.
    func drained(within seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ finished }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > limit { buffer = buffer.suffix(limit) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

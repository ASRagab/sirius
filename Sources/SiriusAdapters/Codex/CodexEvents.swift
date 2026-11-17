import Foundation
import SiriusCore
import SiriusProtocol

// Turns the app-server's notifications about one thread into TurnEvents,
// for an aside. An item's id is the event's id. Checked on 0.159.1
//: item/started names an agentMessage's phase;
// its text comes as item/agentMessage/delta; a command, a patch and the
// other tool items start inProgress and say how they went when they
// complete. A turn that is interrupted completes with its open message
// never completed, so `end` ends whatever is left.
struct CodexEvents {
    private enum Kind {
        case text
        case reasoning
        case tool
    }

    // What has begun and not ended, in the order it began.
    private var open: [(id: String, kind: Kind)] = []

    mutating func hear(_ method: String, _ params: JSONValue) -> [TurnEvent] {
        switch method {
        case "item/started":
            guard let item = params["item"], let id = item["id"]?.string, kind(of: id) == nil else { return [] }
            switch item["type"]?.string {
            case "agentMessage":
                open.append((id, .text))
                return [.textStarted(id: id, phase: Self.phase(item))]
            case "reasoning":
                open.append((id, .reasoning))
                return [.reasoningStarted(id: id)]
            default:
                guard var call = Self.toolCall(item, id: id) else { return [] }
                if call.status == .completed || call.status == .failed { return [.toolCall(call)] }
                call.status = .inProgress
                open.append((id, .tool))
                return [.toolCall(call)]
            }
        case "item/agentMessage/delta":
            guard let id = params["itemId"]?.string, let text = params["delta"]?.string, !text.isEmpty else { return [] }
            if kind(of: id) == .text { return [.textDelta(id: id, text: text)] }
            guard kind(of: id) == nil else { return [] }
            open.append((id, .text))
            return [.textStarted(id: id, phase: nil), .textDelta(id: id, text: text)]
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let id = params["itemId"]?.string, let text = params["delta"]?.string, !text.isEmpty else { return [] }
            if kind(of: id) == .reasoning { return [.reasoningDelta(id: id, text: text)] }
            guard kind(of: id) == nil else { return [] }
            open.append((id, .reasoning))
            return [.reasoningStarted(id: id), .reasoningDelta(id: id, text: text)]
        case "item/reasoning/summaryPartAdded":
            // A later part of the summary is a paragraph of its own.
            guard let id = params["itemId"]?.string, kind(of: id) == .reasoning,
                  (params["summaryIndex"]?.number ?? 0) > 0 else { return [] }
            return [.reasoningDelta(id: id, text: "\n\n")]
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            guard let id = params["itemId"]?.string, kind(of: id) == .tool,
                  let text = params["delta"]?.string, !text.isEmpty else { return [] }
            return [.toolCallUpdated(id: id, ToolCallChange(outputDelta: text))]
        case "item/completed":
            guard let item = params["item"], let id = item["id"]?.string else { return [] }
            let was = close(id)
            switch item["type"]?.string {
            case "agentMessage":
                let phase = Self.phase(item)
                if was == .text { return [.textEnded(id: id, phase: phase)] }
                // Never heard of: the whole message at once.
                guard was == nil, let text = item["text"]?.string, !text.isEmpty else { return [] }
                return [.textStarted(id: id, phase: phase), .textDelta(id: id, text: text), .textEnded(id: id, phase: phase)]
            case "reasoning":
                return was == .reasoning ? [.reasoningEnded(id: id)] : []
            default:
                guard var call = Self.toolCall(item, id: id) else { return [] }
                // An item that completes is over, whatever it says.
                if call.status != .failed { call.status = .completed }
                guard was == .tool else { return was == nil ? [.toolCall(call)] : [] }
                let output = item["aggregatedOutput"]?.string
                return [.toolCallUpdated(id: id, ToolCallChange(status: call.status,
                                                                output: output?.isEmpty == false ? output : nil))]
            }
        case "error":
            // One that ends the turn is the turn's failure (TurnEnd).
            guard params["willRetry"] == .bool(true) else { return [] }
            let said = params["error"]?["message"]?.string ?? ""
            return [.notice(Notice(severity: .warning, text: said.isEmpty ? "Retrying" : said, retrying: true))]
        default:
            return []
        }
    }

    // The turn is over: ends what it left open. A tool item that never
    // completed has failed.
    mutating func end() -> [TurnEvent] {
        defer { open = [] }
        return open.map { item in
            switch item.kind {
            case .text: return .textEnded(id: item.id, phase: nil)
            case .reasoning: return .reasoningEnded(id: item.id)
            case .tool: return .toolCallUpdated(id: item.id, ToolCallChange(status: .failed))
            }
        }
    }

    private func kind(of id: String) -> Kind? { open.first { $0.id == id }?.kind }

    private mutating func close(_ id: String) -> Kind? {
        guard let at = open.firstIndex(where: { $0.id == id }) else { return nil }
        return open.remove(at: at).kind
    }

    private static func phase(_ item: JSONValue) -> TextPhase? {
        switch item["phase"]?.string {
        case "commentary": return .commentary
        case "final_answer": return .answer
        default: return nil
        }
    }

    // The tool items, as a call: nil for the items that are not tools (a
    // message, a plan, a compaction, a review).
    private static func toolCall(_ item: JSONValue, id: String) -> ToolCall? {
        guard let type = item["type"]?.string else { return nil }
        var call = ToolCall(id: id, name: type, title: type, kind: .other, status: status(item["status"]?.string))
        switch type {
        case "commandExecution":
            let actions = item["commandActions"]?.array ?? []
            // Codex's own reading of the command, when it is one thing.
            let action = actions.count == 1 ? actions[0] : nil
            call.title = ToolLine.line(action?["command"]?.string ?? item["command"]?.string ?? "")
            switch action?["type"]?.string {
            case "read": call.kind = .read
            case "listFiles", "search": call.kind = .search
            default: call.kind = .execute
            }
        case "fileChange":
            let changes = item["changes"]?.array ?? []
            let names = changes.compactMap { $0["path"]?.string }.map { ($0 as NSString).lastPathComponent }
            call.title = names.isEmpty ? "Edit files"
                : names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
            let kinds = Set(changes.compactMap { $0["kind"]?["type"]?.string })
            call.kind = kinds == ["delete"] ? .delete : .edit
        case "mcpToolCall":
            call.title = [item["server"]?.string, item["tool"]?.string].compactMap { $0 }.joined(separator: ".")
        case "dynamicToolCall", "collabAgentToolCall":
            call.title = item["tool"]?.string ?? type
        case "webSearch":
            call.title = ToolLine.line(item["query"]?.string ?? "")
            call.kind = .search
            // A search item carries no status.
            if item["status"] == nil { call.status = .inProgress }
        case "imageGeneration":
            call.title = "Image"
        default:
            return nil
        }
        if call.title.isEmpty { call.title = type }
        return call
    }

    private static func status(_ said: String?) -> ToolStatus {
        switch said {
        case "completed": return .completed
        case "failed", "declined", "interrupted": return .failed
        default: return .inProgress
        }
    }
}

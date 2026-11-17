import Foundation
import SiriusCore
import SiriusProtocol

// Turns muse serve's notifications about one session into TurnEvents, for
// an aside. An item's id is the event's id. Checked on 1.4.14
//: item/started names an item's kind; item/delta
// then appends to a field of it, "text" when none is named, "output" for a
// tool's, "summary.n" for part n of a reasoning summary; a message's phase
// is said only when it completes. A turn that is cancelled completes with
// its open message never completed, so `end` ends whatever is left.
//
// Kinds are an open set. The ones handed on are the agent's own: its
// messages, its reasoning, its tool calls, searches and subagents. A
// reminderChild and the rest are Muse's housekeeping.
struct MuseEvents {
    private enum Kind: Equatable {
        case text
        // The summary part the last piece belonged to.
        case reasoning(part: String?)
        case tool(title: String)
    }

    // What has begun and not ended, in the order it began.
    private var open: [(id: String, kind: Kind)] = []

    mutating func hear(_ method: String, _ params: JSONValue) -> [TurnEvent] {
        switch method {
        case "item/started":
            guard let item = params["item"], let id = item["itemId"]?.string, at(id) == nil else { return [] }
            switch item["kind"]?.string {
            case "agentMessage":
                open.append((id, .text))
                return [.textStarted(id: id, phase: nil)]
            case "reasoning":
                open.append((id, .reasoning(part: nil)))
                return [.reasoningStarted(id: id)]
            default:
                guard var call = Self.toolCall(item, id: id) else { return [] }
                call.status = .inProgress
                open.append((id, .tool(title: call.title)))
                return [.toolCall(call)]
            }
        case "item/delta":
            guard let id = params["itemId"]?.string, let at = at(id),
                  let text = params["delta"]?.string, !text.isEmpty else { return [] }
            let field = params["field"]?.string ?? "text"
            switch open[at].kind {
            case .text:
                return field == "text" ? [.textDelta(id: id, text: text)] : []
            case .reasoning(let part):
                guard field == "text" || field.hasPrefix("summary") else { return [] }
                open[at].kind = .reasoning(part: field)
                // A later part of the summary is a paragraph of its own.
                let lead = part != nil && part != field ? "\n\n" : ""
                return [.reasoningDelta(id: id, text: lead + text)]
            case .tool:
                return field == "output" ? [.toolCallUpdated(id: id, ToolCallChange(outputDelta: text))] : []
            }
        case "item/updated":
            // A tool call learns its own words for itself after it starts.
            guard let item = params["item"], let id = item["itemId"]?.string, let at = at(id),
                  case .tool(let title) = open[at].kind, let call = Self.toolCall(item, id: id),
                  call.title != title else { return [] }
            open[at].kind = .tool(title: call.title)
            return [.toolCallUpdated(id: id, ToolCallChange(title: call.title))]
        case "item/completed":
            guard let item = params["item"], let id = item["itemId"]?.string else { return [] }
            let was = at(id).map { open.remove(at: $0).kind }
            switch item["kind"]?.string {
            case "agentMessage":
                // No phase on a completed message reads as the answer.
                let phase: TextPhase = item["messagePhase"]?.string == "commentary" ? .commentary : .answer
                if was == .text { return [.textEnded(id: id, phase: phase)] }
                // Never heard of: the whole message at once.
                guard was == nil, let text = item["text"]?.string, !text.isEmpty else { return [] }
                return [.textStarted(id: id, phase: phase), .textDelta(id: id, text: text), .textEnded(id: id, phase: phase)]
            case "reasoning":
                if case .reasoning = was { return [.reasoningEnded(id: id)] }
                return []
            default:
                guard case .tool = was else { return [] }
                // Any status but completed is a way of not finishing.
                let status: ToolStatus = item["status"]?.string == "completed" ? .completed : .failed
                return [.toolCallUpdated(id: id, ToolCallChange(status: status))]
            }
        case "turn/retryScheduled":
            var text = "Retrying"
            if let attempt = params["nextAttempt"]?.number, let limit = params["maxAttempts"]?.number {
                text += " (\(Int(attempt)) of \(Int(limit)))"
            }
            if let reason = params["reason"]?.string, !reason.isEmpty { text += ": \(reason)" }
            return [.notice(Notice(severity: .warning, text: text, retrying: true))]
        default:
            return []
        }
    }

    // The turn is over: ends what it left open. A tool call that never
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

    private func at(_ id: String) -> Int? { open.firstIndex { $0.id == id } }

    // The items that are the agent doing something, as a call.
    private static func toolCall(_ item: JSONValue, id: String) -> ToolCall? {
        switch item["kind"]?.string {
        case "toolCall":
            let tool = item["tool"]?.string ?? "tool"
            // `args` is the model's JSON as it wrote it, which may not parse.
            let input = item["args"]?.string.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                as? [String: Any] ?? [:]
            let label = item["displayLabel"]?.string ?? ""
            return ToolCall(id: id, name: tool,
                            title: label.isEmpty ? ToolLine.title(tool: tool, input: input) : ToolLine.line(label),
                            kind: ToolLine.kind(tool: tool))
        case "webSearch":
            let query = item["query"]?.string ?? item["fallbackText"]?.string ?? ""
            return ToolCall(id: id, name: "webSearch", title: query.isEmpty ? "Web search" : ToolLine.line(query),
                            kind: .search)
        case "subagent":
            let said = item["objective"]?.string ?? item["role"]?.string ?? ""
            return ToolCall(id: id, name: "subagent", title: said.isEmpty ? "Subagent" : ToolLine.line(said))
        default:
            return nil
        }
    }
}

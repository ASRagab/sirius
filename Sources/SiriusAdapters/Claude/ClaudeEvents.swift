import Foundation
import SiriusCore

// Turns the parts of a Claude turn (ClaudeStream.Part) into TurnEvents, for
// an aside. A text or thinking block has no id of its own, so it is named
// by its message and index: "msg_01…:0". A tool call keeps Claude's id.
//
// What the stream does, checked on 2.1.321: a
// message's blocks come one after another, but a tool's result may arrive
// while the next tool block's input is still streaming, so a tool call
// stays open after its block stops, until its result. An interrupted turn
// stops its open block itself; a turn that dies does not, so `end` ends
// whatever is left.
struct ClaudeEvents {
    private enum Block {
        case text(String)
        case reasoning(String)
        case tool(String)
    }

    private var message: String?
    private var unnamed = 0
    private var stepping = false
    private var blocks: [Int: Block] = [:]
    // The tool calls announced and not yet finished, in order.
    private var tools: [String] = []

    mutating func hear(_ part: ClaudeStream.Part) -> [TurnEvent] {
        switch part {
        case .messageStarted(let id):
            var out = endBlocks()
            if stepping { out.append(.stepFinished) }
            message = id ?? nextName()
            stepping = true
            return out + [.stepStarted]
        case .messageStopped:
            var out = endBlocks()
            if stepping { out.append(.stepFinished) }
            stepping = false
            message = nil
            return out
        case .blockStarted(let index, let kind):
            var out = endBlock(index)
            switch kind {
            case .text:
                let id = name(index)
                blocks[index] = .text(id)
                out.append(.textStarted(id: id, phase: nil))
            case .thinking:
                let id = name(index)
                blocks[index] = .reasoning(id)
                out.append(.reasoningStarted(id: id))
            case .tool(let id, let name):
                blocks[index] = .tool(id)
                out += announce(id, name: name, title: "", status: .pending)
            }
            return out
        case .text(let index, let text):
            if case .text(let id) = blocks[index] { return [.textDelta(id: id, text: text)] }
            // A piece with no start before it: the run begins here.
            let id = name(index)
            let out = endBlock(index)
            blocks[index] = .text(id)
            return out + [.textStarted(id: id, phase: nil), .textDelta(id: id, text: text)]
        case .thinking(let index, let text):
            guard case .reasoning(let id) = blocks[index] else { return [] }
            return [.reasoningDelta(id: id, text: text)]
        case .toolInput(let index, let json):
            guard case .tool(let id) = blocks[index] else { return [] }
            return [.toolCallUpdated(id: id, ToolCallChange(inputDelta: json))]
        case .blockStopped(let index):
            return endBlock(index)
        case .toolUse(let id, let name, let title):
            return announce(id, name: name, title: title, status: .inProgress)
        case .toolResult(let id, let failed, let output):
            guard let at = tools.firstIndex(of: id) else { return [] }
            tools.remove(at: at)
            return [.toolCallUpdated(id: id, ToolCallChange(status: failed ? .failed : .completed, output: output))]
        case .retry(let attempt, let limit, let error):
            var text = "Retrying"
            if let attempt, let limit { text += " (\(attempt) of \(limit))" } else if let attempt { text += " (\(attempt))" }
            if let error, !error.isEmpty { text += ": \(error)" }
            return [.notice(Notice(severity: .warning, text: text, retrying: true))]
        }
    }

    // The turn is over: ends what it left open. A tool call that never got
    // its result has failed.
    mutating func end() -> [TurnEvent] {
        var out = endBlocks()
        if stepping { out.append(.stepFinished) }
        out += tools.map { .toolCallUpdated(id: $0, ToolCallChange(status: .failed)) }
        stepping = false
        message = nil
        tools = []
        return out
    }

    private mutating func nextName() -> String {
        unnamed += 1
        return "message-\(unnamed)"
    }

    private mutating func name(_ index: Int) -> String {
        if message == nil { message = nextName() }
        return "\(message ?? ""):\(index)"
    }

    // The first word of a tool call, or what the complete line adds to it.
    private mutating func announce(_ id: String, name: String, title: String, status: ToolStatus) -> [TurnEvent] {
        if tools.contains(id) {
            return [.toolCallUpdated(id: id, ToolCallChange(status: status, title: title.isEmpty ? nil : title))]
        }
        tools.append(id)
        return [.toolCall(ToolCall(id: id, name: name, title: title, kind: ToolLine.kind(tool: name), status: status))]
    }

    private mutating func endBlock(_ index: Int) -> [TurnEvent] {
        switch blocks.removeValue(forKey: index) {
        case .text(let id): return [.textEnded(id: id, phase: nil)]
        case .reasoning(let id): return [.reasoningEnded(id: id)]
        case .tool, nil: return []
        }
    }

    private mutating func endBlocks() -> [TurnEvent] {
        blocks.keys.sorted().flatMap { endBlock($0) }
    }
}

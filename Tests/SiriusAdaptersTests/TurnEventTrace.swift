import Foundation
import SiriusCore
import XCTest

// A turn's events as lines a test can read and compare: one line per
// event, with the pieces of one run, or of one tool call's input, joined.
// Shared by the adapters' tests.
enum TurnEventTrace {
    static func lines(_ events: [TurnEvent]) -> [String] {
        var out: [String] = []
        // The line being joined onto: its key, and its text so far.
        var joining: (key: String, text: String)?
        func flush() {
            if let joining { out.append("\(joining.key) \(quoted(joining.text))") }
            joining = nil
        }
        func join(_ key: String, _ text: String) {
            if joining?.key == key { joining?.text += text } else { flush(); joining = (key, text) }
        }
        for event in events {
            switch event {
            case .textDelta(let id, let text): join("text \(id)", text); continue
            case .reasoningDelta(let id, let text): join("reasoning \(id)", text); continue
            case .toolCallUpdated(let id, let change) where change == ToolCallChange(inputDelta: change.inputDelta)
                && change.inputDelta != nil:
                join("tool \(id) input", change.inputDelta ?? ""); continue
            case .toolCallUpdated(let id, let change) where change == ToolCallChange(outputDelta: change.outputDelta)
                && change.outputDelta != nil:
                join("tool \(id) output", change.outputDelta ?? ""); continue
            default: flush()
            }
            switch event {
            case .stepStarted: out.append("step+")
            case .stepFinished: out.append("step-")
            case .textStarted(let id, let phase): out.append("text+ \(id)\(phase.map { " \($0)" } ?? "")")
            case .textEnded(let id, let phase): out.append("text- \(id)\(phase.map { " \($0)" } ?? "")")
            case .reasoningStarted(let id): out.append("reasoning+ \(id)")
            case .reasoningEnded(let id): out.append("reasoning- \(id)")
            case .toolCall(let call):
                out.append("tool+ \(call.id) \(call.name ?? "-") \(call.kind) \(call.status) \(quoted(call.title))"
                    + (call.parent.map { " under \($0)" } ?? ""))
            case .toolCallUpdated(let id, let change):
                var said: [String] = []
                if let status = change.status { said.append("\(status)") }
                if let title = change.title { said.append("title \(quoted(title))") }
                if let input = change.inputDelta { said.append("input \(quoted(input))") }
                if let output = change.outputDelta { said.append("output+ \(quoted(output))") }
                if let output = change.output { said.append("output \(quoted(output))") }
                out.append("tool \(id) " + said.joined(separator: ", "))
            case .notice(let notice):
                out.append("notice \(notice.severity)\(notice.retrying ? " retrying" : "") \(quoted(notice.text))")
            case .textDelta, .reasoningDelta: break
            }
        }
        flush()
        return out
    }

    // Short enough to read: the first 60 characters, newlines shown.
    private static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + (flat.count > 60 ? String(flat.prefix(60)) + "…" : flat) + "\""
    }

    // What was started and never ended: runs of text and reasoning, steps,
    // and tool calls that reached no terminal status. Empty after a turn.
    static func unended(_ events: [TurnEvent]) -> [String] {
        var open: [String] = []
        func close(_ key: String) {
            if let at = open.firstIndex(of: key) { open.remove(at: at) } else { open.append("stray end of \(key)") }
        }
        for event in events {
            switch event {
            case .stepStarted: open.append("step")
            case .stepFinished: close("step")
            case .textStarted(let id, _): open.append("text \(id)")
            case .textEnded(let id, _): close("text \(id)")
            case .reasoningStarted(let id): open.append("reasoning \(id)")
            case .reasoningEnded(let id): close("reasoning \(id)")
            case .toolCall(let call):
                if call.status != .completed, call.status != .failed { open.append("tool \(call.id)") }
            case .toolCallUpdated(let id, let change):
                if change.status == .completed || change.status == .failed { close("tool \(id)") }
            default: break
            }
        }
        return open
    }

    // The lines of a recorded stream under Fixtures/.
    static func fixture(_ name: String) throws -> [Data] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    }
}

import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// CodexEvents against turns recorded from codex app-server 0.159.1
// (Fixtures/).
final class CodexEventsTests: XCTestCase {
    private func replay(_ name: String) throws -> (events: [TurnEvent], state: CodexEvents) {
        var state = CodexEvents()
        var out: [TurnEvent] = []
        for line in try TurnEventTrace.fixture(name) {
            let message = try JSONDecoder().decode(JSONValue.self, from: line)
            guard let method = message["method"]?.string, method != "turn/completed" else { continue }
            out += state.hear(method, message["params"] ?? .null)
        }
        return (out, state)
    }

    // A remark, a command, then the answer. Codex names each message's
    // phase when it starts; the command is fast and streams no output.
    func testAToolTurnIsCommentaryACommandAndTheAnswer() throws {
        let (events, _) = try replay("codex-tool")
        let remark = "msg_0fba23216dae092c016af27549b6ec87d0a168b21e5ded623b"
        let command = "exec-3fe04629-1160-469e-a3e7-fd25b37e9056"
        let answer = "msg_0fba23216dae092c016af2754cbe6087d0ba3393ec9ff30f0c"
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "text+ \(remark) commentary",
            "text \(remark) \"I’ll list the current directory with `ls -la`, then describe…\"",
            "text- \(remark) commentary",
            "tool+ \(command) commandExecution search inProgress \"ls -la\"",
            "tool \(command) completed, output \"total 16\\ndrwxr-xr-x@ 4 user  wheel  128 Nov  9 17:36 .\\ndrw…\"",
            "text+ \(answer) answer",
            "text \(answer) \"The directory contains two files: `a.txt`, a 6-byte text fil…\"",
            "text- \(answer) answer",
        ])
        XCTAssertEqual(TurnEventTrace.unended(events), [])
    }

    // Codex completes an interrupted turn without completing its message.
    func testAnInterruptedTurnLeavesItsMessageForTheAdapterToEnd() throws {
        var (events, state) = try replay("codex-interrupt")
        let answer = "msg_0729aa1d9eb4385b016af27546a7c887d081e0455e359f54cf"
        XCTAssertEqual(TurnEventTrace.unended(events), ["text \(answer)"])
        events += state.end()
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "text+ \(answer) answer",
            "text \(answer) \"Lighthouses have guided sailors for more\"",
            "text- \(answer)",
        ])
        XCTAssertEqual(state.end(), [], "nothing is ended twice")
    }

    // From the schema of 0.159.1; none of these has been recorded.
    func testItemsNotRecordedMapByTheirSchema() throws {
        func value(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        var state = CodexEvents()
        var events: [TurnEvent] = []
        for (method, params) in [
            ("item/started", #"{"item":{"type":"reasoning","id":"r","summary":[],"content":[]}}"#),
            ("item/reasoning/summaryTextDelta", #"{"itemId":"r","summaryIndex":0,"delta":"Plan"}"#),
            ("item/reasoning/summaryPartAdded", #"{"itemId":"r","summaryIndex":1}"#),
            ("item/reasoning/summaryTextDelta", #"{"itemId":"r","summaryIndex":1,"delta":"Check"}"#),
            ("item/completed", #"{"item":{"type":"reasoning","id":"r"}}"#),
            ("item/started", #"{"item":{"type":"commandExecution","id":"c","command":"/bin/zsh -lc 'swift build && swift test'","status":"inProgress","commandActions":[{"type":"unknown","command":"swift build"},{"type":"unknown","command":"swift test"}]}}"#),
            ("item/commandExecution/outputDelta", #"{"itemId":"c","delta":"Building"}"#),
            ("item/commandExecution/outputDelta", #"{"itemId":"c","delta":"…"}"#),
            ("item/completed", #"{"item":{"type":"commandExecution","id":"c","command":"x","status":"failed","aggregatedOutput":"error","exitCode":1}}"#),
            ("item/started", #"{"item":{"type":"fileChange","id":"f","status":"inProgress","changes":[{"path":"/r/a.swift","kind":{"type":"update"},"diff":""},{"path":"/r/b.swift","kind":{"type":"add"},"diff":""}]}}"#),
            ("item/completed", #"{"item":{"type":"fileChange","id":"f","status":"declined","changes":[]}}"#),
            ("item/started", #"{"item":{"type":"webSearch","id":"w","query":"lighthouses"}}"#),
            ("item/completed", #"{"item":{"type":"webSearch","id":"w","query":"lighthouses"}}"#),
            ("item/started", #"{"item":{"type":"mcpToolCall","id":"m","server":"linear","tool":"get_issue","status":"inProgress"}}"#),
            ("error", #"{"error":{"message":"stream disconnected"},"willRetry":true}"#),
            ("error", #"{"error":{"message":"out of credits"},"willRetry":false}"#),
            // Not tools, and not ours to show.
            ("item/started", #"{"item":{"type":"userMessage","id":"u","content":[]}}"#),
            ("item/started", #"{"item":{"type":"contextCompaction","id":"x"}}"#),
            ("item/plan/delta", #"{"itemId":"p","delta":"1."}"#),
            // A message that was never started or streamed arrives whole.
            ("item/completed", #"{"item":{"type":"agentMessage","id":"a","text":"Done.","phase":"final_answer"}}"#),
        ] { events += state.hear(method, try value(params)) }
        events += state.end()
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "reasoning+ r", "reasoning r \"Plan\\n\\nCheck\"", "reasoning- r",
            "tool+ c commandExecution execute inProgress \"/bin/zsh -lc 'swift build && swift test'\"",
            "tool c output \"Building…\"",
            "tool c failed, output \"error\"",
            "tool+ f fileChange edit inProgress \"a.swift and 1 more\"",
            "tool f failed",
            "tool+ w webSearch search inProgress \"lighthouses\"",
            "tool w completed",
            "tool+ m mcpToolCall other inProgress \"linear.get_issue\"",
            "notice warning retrying \"stream disconnected\"",
            "text+ a answer", "text a \"Done.\"", "text- a answer",
            // Left open: ended with the turn.
            "tool m failed",
        ])
        XCTAssertEqual(TurnEventTrace.unended(events), [])
    }
}

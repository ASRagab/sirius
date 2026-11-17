import Foundation
import SiriusCore
import XCTest
@testable import SiriusAdapters

// ClaudeStream.parts and ClaudeEvents against turns recorded from Claude
// Code 2.1.321 with --include-partial-messages (Fixtures/).
final class ClaudeEventsTests: XCTestCase {
    private func replay(_ name: String, end: Bool = true) throws -> [TurnEvent] {
        var events = ClaudeEvents()
        var out: [TurnEvent] = []
        for line in try TurnEventTrace.fixture(name) {
            let object = try XCTUnwrap(ClaudeStream.decode(line))
            for part in ClaudeStream.parts(object) { out += events.hear(part) }
        }
        return end ? out + events.end() : out
    }

    // One sentence, a Bash call, then two Reads asked for in one message,
    // then the answer. The first Read's result arrives while the second's
    // input is still streaming.
    func testAToolTurnIsStepsRunsAndToolCallsInTheOrderHeard() throws {
        let events = try replay("claude-tool", end: false)
        let bash = "toolu_01S1iLpZJQMYxHshsPiRZDVz"
        let first = "toolu_01P38oBvqH7RhPobRZ1xaddY"
        let second = "toolu_01BP6gWT5bRBoyViFefC7J7e"
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "step+",
            "text+ msg_011CgtPeK35tisv61ugJL8q2:0",
            "text msg_011CgtPeK35tisv61ugJL8q2:0 \"I'm going to list the contents of the current directory with…\"",
            "text- msg_011CgtPeK35tisv61ugJL8q2:0",
            "tool+ \(bash) Bash execute pending \"\"",
            "tool \(bash) input \"{\"command\": \"ls -la\", \"description\": \"List files in current …\"",
            "tool \(bash) inProgress, title \"ls -la\"",
            "step-",
            "tool \(bash) completed, output \"total 16\\ndrwxr-xr-x@ 4 user  wheel  128 Nov  9 17:36 .\\ndrw…\"",
            "step+",
            "reasoning+ msg_011CgtPeVHjgH1o9eTyiYy6b:0",
            "reasoning- msg_011CgtPeVHjgH1o9eTyiYy6b:0",
            "tool+ \(first) Read read pending \"\"",
            "tool \(first) input \"{\"file_path\": \"/private/tmp/claude-501/-Users-user-Documents…\"",
            "tool \(first) inProgress, title \"a.txt\"",
            "tool+ \(second) Read read pending \"\"",
            "tool \(first) completed, output \"1\talpha\\n2\t\"",
            "tool \(second) input \"{\"file_path\": \"/private/tmp/claude-501/-Users-user-Documents…\"",
            "tool \(second) inProgress, title \"notes.md\"",
            "tool \(second) completed, output \"1\t# Notes\\n2\t\\n3\tTwo lines.\\n4\t\"",
            "step-",
            "step+",
            "text+ msg_011CgtPej7BwGhLhUFTKAptB:0",
            "text msg_011CgtPej7BwGhLhUFTKAptB:0 \"The directory holds two small files, both created today at 1…\"",
            "text- msg_011CgtPej7BwGhLhUFTKAptB:0",
            "step-",
        ])
        XCTAssertEqual(TurnEventTrace.unended(events), [], "Claude ended everything itself")
    }

    // Claude stops the open block itself when the turn is interrupted.
    func testAnInterruptedTurnEndsItsRun() throws {
        let events = try replay("claude-interrupt", end: false)
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "step+",
            "text+ msg_011CgtPeJqw3VCA2kMBVN8ve:0",
            "text msg_011CgtPeJqw3VCA2kMBVN8ve:0 \"Lighthouses began as fires on hilltops. Ancient mariners in …\"",
            "text- msg_011CgtPeJqw3VCA2kMBVN8ve:0",
            "step-",
        ])
        XCTAssertEqual(TurnEventTrace.unended(events), [])
    }

    // A process that dies sends no stops: `end` ends what is open, and a
    // tool call with no result has failed.
    func testATurnThatDiesIsEndedByTheAdapter() throws {
        var events = ClaudeEvents()
        var out: [TurnEvent] = []
        for part: ClaudeStream.Part in [
            .messageStarted(id: "m"), .blockStarted(index: 0, .thinking), .thinking(index: 0, "hm"),
            .blockStopped(index: 0), .blockStarted(index: 1, .tool(id: "t1", name: "Bash")),
            .toolUse(id: "t1", name: "Bash", title: "sleep 9"), .blockStopped(index: 1),
            .blockStarted(index: 2, .text), .text(index: 2, "Wait"),
        ] { out += events.hear(part) }
        XCTAssertEqual(TurnEventTrace.unended(out), ["step", "tool t1", "text m:2"])
        out += events.end()
        XCTAssertEqual(TurnEventTrace.lines(out).suffix(3), ["text- m:2", "step-", "tool t1 failed"])
        XCTAssertEqual(TurnEventTrace.unended(out), [])
        XCTAssertEqual(events.end(), [], "nothing is ended twice")
    }

    func testPartsOfTheMainThreadsLines() {
        func parts(_ line: String) -> [ClaudeStream.Part] {
            ClaudeStream.decode(Data(line.utf8)).map(ClaudeStream.parts) ?? []
        }
        XCTAssertEqual(parts(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"Hel"}}}"#),
                       [.text(index: 3, "Hel")])
        XCTAssertEqual(parts(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}}"#),
                       [.thinking(index: 0, "hm")])
        XCTAssertEqual(parts(#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"Grep"}}}"#),
                       [.blockStarted(index: 1, .tool(id: "t", name: "Grep"))])
        XCTAssertEqual(parts(#"{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","id":"t","name":"Grep","input":{"pattern":"TODO\nmore"}}]}}"#),
                       [.toolUse(id: "t", name: "Grep", title: "TODO")])
        XCTAssertEqual(parts(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true,"content":[{"type":"text","text":"no"},{"type":"text","text":"match"}]}]}}"#),
                       [.toolResult(id: "t", failed: true, output: "no\nmatch")])
        // From the documented shape; no retry has been recorded.
        XCTAssertEqual(parts(#"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"error":"overloaded"}"#),
                       [.retry(attempt: 2, limit: 10, error: "overloaded")])
        XCTAssertEqual(ClaudeEvents().hearing(.retry(attempt: 2, limit: 10, error: "overloaded")),
                       [.notice(Notice(severity: .warning, text: "Retrying (2 of 10): overloaded", retrying: true))])
        // Not handed on: empty pieces, a signature, a subagent's lines, our
        // own line echoed back, lines of other kinds.
        XCTAssertEqual(parts(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}}"#), [])
        XCTAssertEqual(parts(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"s"}}}"#), [])
        XCTAssertEqual(parts(#"{"type":"stream_event","parent_tool_use_id":"toolu_1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sub"}}}"#), [])
        XCTAssertEqual(parts(#"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#), [])
        XCTAssertEqual(parts(#"{"type":"user","isReplay":true,"message":{"content":[{"type":"text","text":"hi"}]}}"#), [])
        XCTAssertEqual(parts(#"{"type":"system","subtype":"status","status":"requesting"}"#), [])
        XCTAssertEqual(parts(#"{"type":"result","subtype":"success"}"#), [])
    }
}

private extension ClaudeEvents {
    func hearing(_ part: ClaudeStream.Part) -> [TurnEvent] {
        var copy = self
        return copy.hear(part)
    }
}

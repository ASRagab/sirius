import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// MuseEvents against turns recorded from muse serve 1.4.14 (Fixtures/).
final class MuseEventsTests: XCTestCase {
    private func replay(_ name: String) throws -> (events: [TurnEvent], state: MuseEvents) {
        var state = MuseEvents()
        var out: [TurnEvent] = []
        for line in try TurnEventTrace.fixture(name) {
            let message = try JSONDecoder().decode(JSONValue.self, from: line)
            guard let method = message["method"]?.string, method != "turn/completed" else { continue }
            out += state.hear(method, message["params"] ?? .null)
        }
        return (out, state)
    }

    // A bash call, the answer, then, after Muse's reminder children ran, a
    // second answer in the same turn. Muse names a message's phase only
    // when it completes, and no reminderChild is handed on.
    func testAToolTurnIsACallAndEachAnswerARunOfItsOwn() throws {
        let (events, _) = try replay("muse-tool")
        let call = "01a1c31a-7e40-7fe3-a815-db9876d698de"
        let first = "0bb43016-e959-4528-8c19-bf57548562a2"
        let second = "b0d62e12-cf0a-4684-bc36-fcdea55d145c"
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "tool+ \(call) bash execute inProgress \"ls -la\"",
            "tool \(call) output \"total 16\\ndrwxr-xr-x@ 4 501  wheel  128 Nov  9 17:36 .\\ndrwx…\"",
            "tool \(call) completed",
            "text+ \(first)",
            "text \(first) \"The directory contains only two regular files besides the st…\"",
            "text- \(first) answer",
            "text+ \(second)",
            "text \(second) \"I am about to run `ls -la` in the current directory and desc…\"",
            "text- \(second) answer",
        ])
        XCTAssertEqual(TurnEventTrace.unended(events), [])
    }

    // Muse completes a cancelled turn without completing its message.
    func testACancelledTurnLeavesItsMessageForTheAdapterToEnd() throws {
        var (events, state) = try replay("muse-interrupt")
        let answer = "e49e0345-1f50-4f41-aee1-774047496db1"
        XCTAssertEqual(TurnEventTrace.unended(events), ["text \(answer)"])
        events += state.end()
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "text+ \(answer)",
            "text \(answer) \"The history of lighthouses is a history of humanity's long n…\"",
            "text- \(answer)",
        ])
        XCTAssertEqual(state.end(), [], "nothing is ended twice")
    }

    // From the schema of 1.4.14; none of these has been recorded.
    func testItemsNotRecordedMapByTheirSchema() throws {
        func value(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        var state = MuseEvents()
        var events: [TurnEvent] = []
        for (method, params) in [
            ("item/started", #"{"item":{"itemId":"r","kind":"reasoning","status":"inProgress"}}"#),
            ("item/delta", #"{"itemId":"r","field":"summary.0","delta":"Plan"}"#),
            ("item/delta", #"{"itemId":"r","field":"summary.1","delta":"Check"}"#),
            ("item/completed", #"{"item":{"itemId":"r","kind":"reasoning","status":"completed"}}"#),
            ("item/started", #"{"item":{"itemId":"m","kind":"agentMessage","status":"inProgress","text":""}}"#),
            ("item/delta", #"{"itemId":"m","delta":"Looking."}"#),
            ("item/delta", #"{"itemId":"m","field":"other","delta":"x"}"#),
            ("item/completed", #"{"item":{"itemId":"m","kind":"agentMessage","status":"completed","messagePhase":"commentary"}}"#),
            ("item/started", #"{"item":{"itemId":"e","kind":"toolCall","status":"inProgress","tool":"edit","args":"{\"file_path\":\"/r/a.swift\""}}"#),
            ("item/updated", #"{"item":{"itemId":"e","kind":"toolCall","status":"inProgress","tool":"edit","displayLabel":"Edit a.swift"}}"#),
            ("item/updated", #"{"item":{"itemId":"e","kind":"toolCall","status":"inProgress","tool":"edit","displayLabel":"Edit a.swift"}}"#),
            ("item/completed", #"{"item":{"itemId":"e","kind":"toolCall","status":"rejected","tool":"edit"}}"#),
            ("item/started", #"{"item":{"itemId":"w","kind":"webSearch","status":"inProgress"}}"#),
            ("item/started", #"{"item":{"itemId":"s","kind":"subagent","status":"inProgress","objective":"Find the bug\nin the parser","role":"explorer"}}"#),
            ("turn/retryScheduled", #"{"attempt":1,"nextAttempt":2,"maxAttempts":5,"reason":"overloaded","retryDelayMs":2000}"#),
            // Muse's own housekeeping, and kinds not known.
            ("item/started", #"{"item":{"itemId":"c","kind":"reminderChild","status":"inProgress"}}"#),
            ("item/delta", #"{"itemId":"c","delta":"x"}"#),
            ("item/completed", #"{"item":{"itemId":"c","kind":"reminderChild","status":"completed"}}"#),
            ("item/started", #"{"item":{"itemId":"n","kind":"somethingNew","status":"inProgress"}}"#),
            ("item/completed", #"{"item":{"itemId":"u","kind":"userMessage","status":"completed","text":"hi"}}"#),
            // A message that was never started arrives whole.
            ("item/completed", #"{"item":{"itemId":"a","kind":"agentMessage","status":"completed","text":"Done."}}"#),
        ] { events += state.hear(method, try value(params)) }
        events += state.end()
        XCTAssertEqual(TurnEventTrace.lines(events), [
            "reasoning+ r", "reasoning r \"Plan\\n\\nCheck\"", "reasoning- r",
            "text+ m", "text m \"Looking.\"", "text- m commentary",
            // Its args did not parse: the tool's name stands in.
            "tool+ e edit edit inProgress \"edit\"",
            "tool e title \"Edit a.swift\"",
            "tool e failed",
            "tool+ w webSearch search inProgress \"Web search\"",
            "tool+ s subagent other inProgress \"Find the bug\"",
            "notice warning retrying \"Retrying (2 of 5): overloaded\"",
            "text+ a answer", "text a \"Done.\"", "text- a answer",
            // Left open: ended with the turn.
            "tool w failed", "tool s failed",
        ])
        XCTAssertEqual(TurnEventTrace.unended(events), [])
    }
}

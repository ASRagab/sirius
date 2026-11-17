import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class AsideSessionTests: XCTestCase {
    // Plays an aside's harness: each turn says its script through onEvent,
    // then ends.
    final class Harness: Adapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _opens: [SessionRequest] = []
        private var _prompts: [String] = []
        private var _closes = 0
        var options: AsideOptions?
        var script: [String] = ["Hello", ", ", "world"]
        // When set, said in place of `script`.
        var events: [TurnEvent]?
        var openSession: String? = "fork-1"
        var failOpens = 0
        var throwOnPrompt: Set<String> = []
        var failTurn: Set<String> = []
        var turnDelay: Double = 0

        let updates: AsyncStream<SessionUpdate>
        private let sink: AsyncStream<SessionUpdate>.Continuation

        init() { (updates, sink) = makeUpdateStream() }

        var opens: [SessionRequest] { lock.withLock { _opens } }
        var prompts: [String] { lock.withLock { _prompts } }
        var closes: Int { lock.withLock { _closes } }

        struct Gone: Error {}

        func open(_ request: SessionRequest) async throws -> SessionInfo {
            let fail = lock.withLock { () -> Bool in
                _opens.append(request)
                if failOpens > 0 { failOpens -= 1; return true }
                return false
            }
            if fail { throw Gone() }
            return SessionInfo(session: request.fork ? openSession : request.resume)
        }

        func prompt(_ message: Message) async throws -> TurnEnd {
            lock.withLock { _prompts.append(message.text) }
            if throwOnPrompt.contains(message.text) { throw Gone() }
            if let events {
                for event in events { options?.onEvent(event) }
            } else {
                options?.onEvent(.textStarted(id: "t", phase: nil))
                for piece in script {
                    if turnDelay > 0 { try await Task.sleep(nanoseconds: UInt64(turnDelay * 1_000_000_000)) }
                    options?.onEvent(.textDelta(id: "t", text: piece))
                }
                options?.onEvent(.textEnded(id: "t", phase: nil))
            }
            return TurnEnd(session: openSession,
                           outcome: failTurn.contains(message.text) ? .failed("model refused") : .completed)
        }

        func steer(_ message: Message) async -> SteerResult { .notJoined }
        func compact() async throws -> Consolidation? { nil }
        func close() async { lock.withLock { _closes += 1 } }
    }

    private func make(_ harness: Harness, parent: String? = "main-1") -> AsideSession {
        AsideSession(agent: "claude", parent: parent) { options in
            harness.options = options
            return harness
        }
    }

    // Events up to and including the `turns`th turn end.
    private func collect(_ session: AsideSession, turns: Int) async -> [AsideSession.Event] {
        var events: [AsideSession.Event] = []
        var ended = 0
        for await event in session.events {
            events.append(event)
            if case .turnEnded = event {
                ended += 1
                if ended == turns { break }
            }
        }
        return events
    }

    func testTheAsideForksTheAgentsSessionAndRunsUnderTheAsideInstructions() async {
        let harness = Harness()
        let session = make(harness)
        XCTAssertEqual(harness.options?.instructions, AsidePrompts.instructions)
        await session.warm()
        XCTAssertEqual(harness.opens, [SessionRequest(resume: "main-1", fork: true)])
        let named = await session.session
        XCTAssertEqual(named, "fork-1")
        XCTAssertTrue(session.id.hasPrefix("a_"))
    }

    func testWithNoSessionToForkTheAsideStartsEmpty() async {
        let harness = Harness()
        let session = make(harness, parent: nil)
        await session.warm()
        XCTAssertEqual(harness.opens, [SessionRequest(resume: nil, fork: false)])
    }

    func testATurnsTextArrivesInOrderThenItsEnd() async {
        let harness = Harness()
        let session = make(harness)
        await session.send("why?")
        let events = await collect(session, turns: 1)
        XCTAssertEqual(events, [
            .event(.textStarted(id: "t", phase: nil)), .event(.textDelta(id: "t", text: "Hello")),
            .event(.textDelta(id: "t", text: ", ")), .event(.textDelta(id: "t", text: "world")),
            .event(.textEnded(id: "t", phase: nil)), .turnEnded(failure: nil),
        ])
        XCTAssertEqual(harness.prompts, ["why?"])
        let transcript = await session.transcript
        XCTAssertEqual(transcript, [.init(role: .user, text: "why?"), .init(role: .agent, text: "Hello, world")])
    }

    func testTheTranscriptKeepsTheAnswersRunsAsParagraphsAndLeavesOutCommentary() async {
        let harness = Harness()
        harness.events = [
            .textStarted(id: "a", phase: .commentary), .textDelta(id: "a", text: "Looking."),
            .textEnded(id: "a", phase: .commentary),
            .toolCall(ToolCall(id: "c", title: "ls", kind: .execute, status: .inProgress)),
            .textStarted(id: "b", phase: nil), .textDelta(id: "b", text: "Two "),
            .toolCallUpdated(id: "c", ToolCallChange(status: .completed)),
            .textStarted(id: "d", phase: nil), .textDelta(id: "d", text: "A remark"),
            .textDelta(id: "b", text: "files."), .textEnded(id: "b", phase: .answer),
            // Muse says a run was commentary only when it ends.
            .textEnded(id: "d", phase: .commentary),
            .textStarted(id: "e", phase: nil), .textEnded(id: "e", phase: nil),
            .textStarted(id: "f", phase: .answer), .textDelta(id: "f", text: "Done."),
        ]
        let session = make(harness)
        await session.send("list")
        let events = await collect(session, turns: 1)
        XCTAssertEqual(events.count, harness.events!.count + 1, "every event is handed on, then the end")
        let transcript = await session.transcript
        XCTAssertEqual(transcript.last, .init(role: .agent, text: "Two files.\n\nDone."))
    }

    func testTurnsRunOneAtATimeInTheOrderSentAndOpenOnce() async {
        let harness = Harness()
        harness.turnDelay = 0.005
        let session = make(harness)
        await session.send("one")
        await session.send("two")
        await session.send("three")
        let events = await collect(session, turns: 3)
        XCTAssertEqual(harness.prompts, ["one", "two", "three"])
        XCTAssertEqual(harness.opens.count, 1)
        XCTAssertEqual(events.filter { $0 == .turnEnded(failure: nil) }.count, 3)
        let transcript = await session.transcript
        XCTAssertEqual(transcript.map(\.role), [.user, .agent, .user, .agent, .user, .agent])
    }

    func testAFailedTurnSaysWhyAndTheNextOneStillRuns() async {
        let harness = Harness()
        harness.failTurn = ["bad"]
        let session = make(harness)
        await session.send("bad")
        await session.send("good")
        let events = await collect(session, turns: 2)
        XCTAssertTrue(events.contains(.turnEnded(failure: "model refused")))
        XCTAssertEqual(events.last, .turnEnded(failure: nil))
        XCTAssertEqual(harness.opens.count, 1)
    }

    func testALostHarnessFailsTheTurnAndTheNextReopensTheAsidesOwnSession() async {
        let harness = Harness()
        harness.throwOnPrompt = ["boom"]
        let session = make(harness)
        await session.send("first")
        await session.send("boom")
        await session.send("after")
        let events = await collect(session, turns: 3)
        let ends = events.compactMap { event -> String?? in
            if case .turnEnded(let failure) = event { return .some(failure) }
            return nil
        }
        XCTAssertNil(ends[0])
        XCTAssertNotNil(ends[1])
        XCTAssertNil(ends[2])
        // The fork once; after the loss, the aside's own session, not a new fork.
        XCTAssertEqual(harness.opens, [SessionRequest(resume: "main-1", fork: true), SessionRequest(resume: "fork-1")])
    }

    func testAHarnessThatDoesNotStartFailsTheTurnAndIsTriedAgain() async {
        let harness = Harness()
        harness.failOpens = 1
        let session = make(harness)
        await session.send("one")
        await session.send("two")
        let events = await collect(session, turns: 2)
        guard case .turnEnded(let first?) = events.first else { return XCTFail("\(events)") }
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(events.last, .turnEnded(failure: nil))
        XCTAssertEqual(harness.opens, [SessionRequest(resume: "main-1", fork: true),
                                       SessionRequest(resume: "main-1", fork: true)])
    }

    func testCloseStopsTheHarnessFinishesTheEventsAndTakesNoMoreTurns() async {
        let harness = Harness()
        let session = make(harness)
        await session.send("one")
        _ = await collect(session, turns: 1)
        await session.close()
        XCTAssertGreaterThanOrEqual(harness.closes, 1)
        await session.send("two")
        var rest: [AsideSession.Event] = []
        for await event in session.events { rest.append(event) }
        XCTAssertEqual(rest, [])
        XCTAssertEqual(harness.prompts, ["one"])
        let busy = await session.isBusy
        XCTAssertFalse(busy)
    }

    func testClosingMidTurnKeepsWhatWasSaid() async {
        let harness = Harness()
        harness.turnDelay = 0.05
        let session = make(harness)
        await session.send("long")
        for await event in session.events {
            if case .event(.textDelta) = event { break }
        }
        await session.close()
        let transcript = await session.transcript
        XCTAssertEqual(transcript.first, .init(role: .user, text: "long"))
        XCTAssertEqual(transcript.last?.role, .agent)
        XCTAssertTrue(transcript.last?.text.hasPrefix("Hello") ?? false)
    }

    // MARK: Prompts

    func testTheTopicIsTheFirstLineShortened() {
        XCTAssertEqual(AsidePrompts.topic(of: "  why the queue?\nmore"), "why the queue?")
        XCTAssertEqual(AsidePrompts.topic(of: String(repeating: "a", count: 200)).count, 121)
    }

    func testTheClosedNoteNamesTheTopicAndWhereItIsKept() {
        let note = AsidePrompts.closedNote(topic: "the queue", turns: 1, transcript: "/tmp/a_1.md")
        XCTAssertTrue(note.contains("\"the queue\""))
        XCTAssertTrue(note.contains("1 exchange,"))
        XCTAssertTrue(note.contains("read /tmp/a_1.md"))
        XCTAssertFalse(AsidePrompts.closedNote(topic: "x", turns: 2, transcript: nil).contains("read "))
        XCTAssertTrue(AsidePrompts.opened(brief: "the diff").contains("\"the diff\""))
    }

    // MARK: Rendering

    func testAnAsideTurnIsTheUsersWordsAlone() {
        XCTAssertEqual(MessageRenderer.renderAside(Message(id: "m_1", agent: "claude", text: "why?")), "why?")
        let attached = Message(id: "m_1", agent: "claude", text: "see",
                               attachments: [.init(path: "/a/b.png", mimeType: "image/png")])
        XCTAssertEqual(MessageRenderer.renderAside(attached),
                       "see\n\n<attachment path=\"/a/b.png\" type=\"image/png\"/>")
    }

    func testNotesFollowTheMessageOutsideItsWrapper() {
        var message = Message(id: "m_1", agent: "claude", text: "hi")
        message.notes = ["an aside closed"]
        let text = MessageRenderer.render(message)
        XCTAssertTrue(text.contains("</sirius message=\"m_1\">\n[Sirius: an aside closed]\n"), text)
    }
}

// Notes (AgentTurnQueue.note): what Sirius leaves for the agent's next turn.
final class AgentTurnQueueNotesTests: XCTestCase {
    final class Recorder: Adapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [Message] = []
        var fail: Set<String> = []
        let updates: AsyncStream<SessionUpdate>
        private let sink: AsyncStream<SessionUpdate>.Continuation
        init() { (updates, sink) = makeUpdateStream() }
        var messages: [Message] { lock.withLock { _messages } }
        func open(_ request: SessionRequest) async throws -> SessionInfo { SessionInfo() }
        func prompt(_ message: Message) async throws -> TurnEnd {
            lock.withLock { _messages.append(message) }
            return TurnEnd(session: nil, outcome: fail.contains(message.id) ? .failed("no") : .completed)
        }
        func steer(_ message: Message) async -> SteerResult { .notJoined }
        func compact() async throws -> Consolidation? { nil }
        func close() async {}
    }

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func wait(_ recorder: Recorder, for count: Int) async throws {
        for _ in 0..<400 where recorder.messages.count < count { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(recorder.messages.count, count)
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testANoteRidesTheNextMessageOnceAndIsKeptUntilThen() async throws {
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        try storage.prepare()
        let recorder = Recorder()
        let queue = AgentTurnQueue(adapter: recorder, log: try storage.openLog(), storage: storage)
        await queue.note("an aside closed")
        XCTAssertEqual(try storage.readState().notes, ["an aside closed"])
        // A second queue on the same storage, as after a restart, still has it.
        let again = AgentTurnQueue(adapter: Recorder(), log: try storage.openLog(), storage: storage)
        let waiting = await again.pendingNotes()
        XCTAssertEqual(waiting, ["an aside closed"])

        try await queue.send(Message(id: "m_1", agent: "dev", text: "one"))
        try await wait(recorder, for: 1)
        try await queue.send(Message(id: "m_2", agent: "dev", text: "two"))
        try await wait(recorder, for: 2)
        XCTAssertEqual(recorder.messages[0].notes, ["an aside closed"])
        XCTAssertNil(recorder.messages[1].notes)
        let left = await queue.pendingNotes()
        XCTAssertEqual(left, [])
        XCTAssertNil(try storage.readState().notes)
    }

    func testANoteStaysWhenTheTurnThatCarriedItFailed() async throws {
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        try storage.prepare()
        let recorder = Recorder()
        recorder.fail = ["m_1"]
        let queue = AgentTurnQueue(adapter: recorder, log: try storage.openLog(), storage: storage)
        await queue.note("an aside closed")
        try await queue.send(Message(id: "m_1", agent: "dev", text: "one"))
        try await wait(recorder, for: 1)
        try await queue.send(Message(id: "m_2", agent: "dev", text: "two"))
        try await wait(recorder, for: 2)
        XCTAssertEqual(recorder.messages[1].notes, ["an aside closed"])
    }
}

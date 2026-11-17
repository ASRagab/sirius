import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

final class AgentTurnQueueTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("turnqueue-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeQueue(_ adapter: FakeAdapter, consolidation: ConsolidationPolicy? = nil) throws
        -> (AgentTurnQueue, AgentStorage, AgentLog) {
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        try storage.prepare()
        let log = try storage.openLog()
        return (AgentTurnQueue(adapter: adapter, log: log, storage: storage, consolidation: consolidation),
                storage, log)
    }

    private static let quick = ConsolidationPolicy(idle: .milliseconds(50), threshold: 100_000)

    private func message(_ n: Int) -> Message {
        Message(id: "m_\(n)", agent: "dev", text: "message \(n)")
    }

    func testMessagesArriveInOrderOneTurnAtATime() async throws {
        let adapter = FakeAdapter(turnDelay: 0.02)
        let (queue, _, _) = try makeQueue(adapter)
        for n in 1...5 { try await queue.send(message(n)) }
        try await adapter.waitForDeliveries(5)
        XCTAssertEqual(adapter.delivered, ["m_1", "m_2", "m_3", "m_4", "m_5"])
        XCTAssertEqual(adapter.maxConcurrent, 1)
        XCTAssertEqual(adapter.starts, [nil])
    }

    func testSessionsArePersistedFromStartAndTurnEnd() async throws {
        let adapter = FakeAdapter(startSession: "thread-1", turnSession: "thread-2")
        let (queue, storage, _) = try makeQueue(adapter)
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try storage.readState().session, "thread-2")
    }

    func testStartResumesTheStoredSession() async throws {
        let adapter = FakeAdapter()
        let (queue, storage, _) = try makeQueue(adapter)
        try storage.writeState(AgentState(session: "old"))
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        XCTAssertEqual(adapter.starts, ["old"])
    }

    func testEachStartIsLoggedWithModelAndWhetherItResumed() async throws {
        let adapter = FakeAdapter(startSession: "old", startModel: "claude-opus-5-5")
        let (queue, storage, _) = try makeQueue(adapter)
        try storage.writeState(AgentState(session: "old"))
        try await queue.warm()
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        guard case .agentStarted(let session, let resumed, let model, _, let ms)? = events.first else {
            return XCTFail("no agent_started: \(events)")
        }
        XCTAssertEqual(session, "old")
        XCTAssertTrue(resumed)
        XCTAssertEqual(model, "claude-opus-5-5")
        XCTAssertGreaterThanOrEqual(ms, 0)
    }

    func testAgentTurnsAreLoggedAndTheirSessionKept() async throws {
        let adapter = FakeAdapter()
        let (queue, storage, _) = try makeQueue(adapter)
        try await queue.warm()
        adapter.agentTurn(TurnEnd(session: "bg-session", outcome: .completed, model: "m"))
        try await Task.sleep(nanoseconds: 100_000_000)
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        XCTAssertTrue(events.contains(.agentTurn(session: "bg-session", outcome: .completed, model: "m")), "\(events)")
        XCTAssertEqual(try storage.readState().session, "bg-session")
    }

    func testFailuresAreReportedButAStopIsNot() async throws {
        final class Reasons: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
        }
        let reasons = Reasons()
        let adapter = FakeAdapter(turnDelay: 0.02, throwOn: ["m_1"])
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        try storage.prepare()
        let queue = AgentTurnQueue(adapter: adapter, log: try storage.openLog(), storage: storage,
                                   onFailure: { reason in reasons.lock.withLock { reasons.all.append(reason) } })
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reasons.lock.withLock { reasons.all.count }, 1)
        try await queue.send(message(2))
        await queue.stop()
        XCTAssertEqual(reasons.lock.withLock { reasons.all.count }, 1)
    }

    // A failure the user can act on reaches them in its own words, once,
    // and not as a bare reason as well.
    func testAUserFacingFailureIsToldInItsOwnWords() async throws {
        final class Told: @unchecked Sendable {
            let lock = NSLock()
            var failures: [String] = []
            var messages: [String] = []
        }
        let told = Told()
        let adapter = FakeAdapter(outdatedOn: ["m_1"])
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        try storage.prepare()
        let queue = AgentTurnQueue(adapter: adapter, log: try storage.openLog(), storage: storage,
                                   onFailure: { reason in told.lock.withLock { told.failures.append(reason) } },
                                   onUserError: { text in told.lock.withLock { told.messages.append(text) } })
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(told.lock.withLock { told.messages }, ["Run `claude update`, then try again."])
        XCTAssertEqual(told.lock.withLock { told.failures }, [])
        await queue.stop()
    }

    func testAGoneAgentIsRestartedBeforeTheNextTurn() async throws {
        let adapter = FakeAdapter(throwOn: ["m_1"])
        let (queue, storage, _) = try makeQueue(adapter)
        try await queue.send(message(1))
        try await queue.send(message(2))
        try await adapter.waitForDeliveries(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(adapter.starts.count, 2)
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        XCTAssertTrue(events.contains { if case .turnEnded("m_1", _, .failed, _) = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .turnEnded("m_2", _, .completed, _) = $0 { true } else { false } })
    }

    func testAMessageSentDuringATurnJoinsItAndEndsWithIt() async throws {
        let adapter = FakeAdapter(turnDelay: 0.3, steers: true)
        let (queue, storage, _) = try makeQueue(adapter)
        try await queue.send(message(1))
        try await adapter.waitForStarted(1)
        try await queue.send(message(2))
        try await queue.send(message(3))
        XCTAssertEqual(adapter.steered, ["m_2", "m_3"])
        try await adapter.waitForDeliveries(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(adapter.delivered, ["m_1"])
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        let started = events.compactMap { if case .turnStarted(let m) = $0 { m } else { nil } }
        let ended = events.compactMap { if case .turnEnded(let m, _, .completed, _) = $0 { m } else { nil } }
        let joined = events.compactMap { if case .turnJoined(let m, "m_1") = $0 { m } else { nil } }
        XCTAssertEqual(started, ["m_1"])
        XCTAssertEqual(joined, ["m_2", "m_3"])
        XCTAssertEqual(ended, ["m_1", "m_2", "m_3"])
    }

    func testAJoinedMessageIsInterruptedWithItsTurn() async throws {
        let adapter = FakeAdapter(turnDelay: 5, steers: true)
        let (queue, storage, _) = try makeQueue(adapter)
        try await queue.send(message(1))
        try await adapter.waitForStarted(1)
        try await queue.send(message(2))
        await queue.stop()
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        let interrupted = events.compactMap { if case .interrupted(let m, _) = $0 { m } else { nil } }
        XCTAssertEqual(interrupted, ["m_1", "m_2"])
    }

    func testARestartInterruptsAJoinedMessageWithItsTurn() async throws {
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        try storage.prepare()
        do {
            let log = try storage.openLog()
            for n in 1...2 { try await log.messageReceived(message(n)) }
            try await log.turnStarted(message: "m_1")
            try await log.turnJoined(message: "m_2", turn: "m_1")
        }
        let reopened = try storage.openLog()
        XCTAssertEqual(reopened.recovered, ["m_1", "m_2"])
        XCTAssertEqual(reopened.requeued.map(\.id), [])
    }

    func testStopInterruptsTheRunningTurnAndLeavesTheQueuedOnesPending() async throws {
        let adapter = FakeAdapter(turnDelay: 5)
        let (queue, storage, log) = try makeQueue(adapter)
        try await queue.send(message(1))
        try await queue.send(message(2))
        try await adapter.waitForStarted(1)
        await queue.stop()
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        let interrupted = events.compactMap { if case .interrupted(let m, _) = $0 { m } else { nil } }
        XCTAssertEqual(interrupted, ["m_1"])
        let pending = await log.pendingMessages
        XCTAssertEqual(pending, ["m_2"])
        do {
            try await queue.send(message(3))
            XCTFail("expected stopped")
        } catch {
            XCTAssertEqual(error as? AgentTurnQueueError, .stopped)
        }
    }

    // MARK: Restart (#1)

    private func turnsStarted(_ storage: AgentStorage) throws -> [String] {
        try AgentLog.read(storage.logURL).entries.compactMap { if case .turnStarted(let m) = $0.event { m } else { nil } }
    }

    // Sirius is killed mid-turn with two messages queued behind it: the next
    // start delivers both, in order and ahead of a new one, and never the
    // turn that was cut off.
    func testMessagesQueuedBehindALongTurnSurviveAKillAndAreDeliveredOnce() async throws {
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        do {
            // What the queue had logged when the process died.
            let log = try storage.openLog()
            try await log.messageReceived(message(1))
            try await log.turnStarted(message: "m_1")
            try await log.messageReceived(message(2))
            try await log.messageReceived(message(3))
        }

        let adapter = FakeAdapter()
        let (queue, _, log) = try makeQueue(adapter)
        XCTAssertEqual(log.recovered, ["m_1"])
        XCTAssertEqual(log.requeued.map(\.id), ["m_2", "m_3"])
        try await queue.warm()
        try await queue.send(message(4))
        try await adapter.waitForDeliveries(3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(adapter.delivered, ["m_2", "m_3", "m_4"])
        XCTAssertEqual(try turnsStarted(storage), ["m_1", "m_2", "m_3", "m_4"])

        // A further restart has nothing to resend.
        let again = try storage.openLog()
        XCTAssertEqual(again.requeued, [])
        XCTAssertEqual(again.recovered, [])
    }

    // The same through a clean stop, as quitting Sirius does.
    func testMessagesQueuedBehindALongTurnSurviveAStopAndAreDeliveredOnce() async throws {
        let first = FakeAdapter(turnDelay: 5)
        let (queue, storage, _) = try makeQueue(first)
        for n in 1...3 { try await queue.send(message(n)) }
        try await first.waitForStarted(1)
        await queue.stop()

        let second = FakeAdapter()
        let (restarted, _, log) = try makeQueue(second)
        XCTAssertEqual(log.recovered, [])
        XCTAssertEqual(log.requeued.map(\.id), ["m_2", "m_3"])
        try await restarted.warm()
        try await second.waitForDeliveries(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(first.delivered, [])
        XCTAssertEqual(second.delivered, ["m_2", "m_3"])
        XCTAssertEqual(try turnsStarted(storage), ["m_1", "m_2", "m_3"])
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        XCTAssertTrue(events.contains(.interrupted(message: "m_1", reason: AgentTurnQueue.stopReason)), "\(events)")
    }

    // A turn cut off mid-run stays interrupted and is not rerun by itself.
    func testAStartedButUnfinishedTurnIsNotRerun() async throws {
        let storage = try AgentStorage(agent: "dev", baseDirectory: base)
        do {
            let log = try storage.openLog()
            try await log.messageReceived(message(1))
            try await log.turnStarted(message: "m_1")
        }
        let adapter = FakeAdapter()
        let (queue, _, log) = try makeQueue(adapter)
        XCTAssertEqual(log.recovered, ["m_1"])
        XCTAssertEqual(log.requeued, [])
        try await queue.warm()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(adapter.delivered, [])
        XCTAssertEqual(try turnsStarted(storage), ["m_1"])
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        XCTAssertEqual(events.filter { $0.message == "m_1" }.map(\.name), ["message", "turn_started", "interrupted"])
        XCTAssertTrue(events.contains(.interrupted(message: "m_1", reason: AgentLog.restartReason)))
    }

    func testARequeuedMessageWhoseAttachmentIsGoneGoesWithItsTextAndANote() {
        let kept = Message.Attachment(path: "/a/kept.png", mimeType: "image/png")
        let gone = Message.Attachment(path: "/a/gone.png", mimeType: "image/png")
        let sent = AgentTurnQueue.deliverable(Message(id: "m_1", agent: "dev", text: "look", attachments: [kept, gone]),
                                              fileExists: { $0 == kept.path })
        XCTAssertEqual(sent.attachments, [kept])
        XCTAssertEqual(sent.text, "look\n\n" + AgentTurnQueue.missingAttachmentNote(gone.path))
        let whole = Message(id: "m_2", agent: "dev", text: "fine", attachments: [kept])
        XCTAssertEqual(AgentTurnQueue.deliverable(whole, fileExists: { _ in true }), whole)
    }

    // MARK: warm()

    func testWarmStartsWithTheStoredSessionAndTheFirstTurnReusesIt() async throws {
        let adapter = FakeAdapter(startSession: "thread-1")
        let (queue, storage, _) = try makeQueue(adapter)
        try storage.writeState(AgentState(session: "old"))
        try await queue.warm()
        XCTAssertEqual(adapter.starts, ["old"])
        XCTAssertEqual(try storage.readState().session, "thread-1")
        try await queue.warm()
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        XCTAssertEqual(adapter.starts, ["old"])
    }

    func testASendDuringWarmJoinsTheStartInFlight() async throws {
        let adapter = FakeAdapter(startDelay: 0.2)
        let (queue, _, _) = try makeQueue(adapter)
        async let warming: Void = queue.warm()
        try await Task.sleep(nanoseconds: 20_000_000)
        try await queue.send(message(1))
        try await queue.send(message(2))
        try await warming
        try await adapter.waitForDeliveries(2)
        XCTAssertEqual(adapter.starts.count, 1)
        XCTAssertEqual(adapter.delivered, ["m_1", "m_2"])
        XCTAssertEqual(adapter.maxConcurrent, 1)
    }

    func testStopDuringWarmLeavesTheAgentStopped() async throws {
        let adapter = FakeAdapter(startDelay: 0.2)
        let (queue, _, _) = try makeQueue(adapter)
        async let warming: Void = queue.warm()
        try await Task.sleep(nanoseconds: 20_000_000)
        await queue.stop()
        // stop() returned after the start it overlapped finished, and stopped it.
        let stopsAfterStop = adapter.stops
        XCTAssertGreaterThanOrEqual(stopsAfterStop, 2)
        do {
            try await warming
            XCTFail("expected stopped")
        } catch {
            XCTAssertEqual(error as? AgentTurnQueueError, .stopped)
        }
        try await queue.warm()
        XCTAssertEqual(adapter.starts.count, 1)
    }
}

extension AgentTurnQueueTests {
    func testAnIdleAgentOverTheThresholdIsConsolidatedOnceAndLogged() async throws {
        let adapter = FakeAdapter(context: 150_000)
        let (queue, storage, _) = try makeQueue(adapter, consolidation: Self.quick)
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(adapter.consolidations, 1, "the context is unknown after, so it does not run again")
        let events = try AgentLog.read(storage.logURL).entries.map(\.event)
        XCTAssertTrue(events.contains(.consolidated(before: 150_000, after: 9000, milliseconds: 5,
                                                    outcome: .completed)), "\(events)")
    }

    func testAnAgentUnderTheThresholdIsLeftAlone() async throws {
        let adapter = FakeAdapter(context: 40_000)
        let (queue, _, _) = try makeQueue(adapter, consolidation: Self.quick)
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(adapter.consolidations, 0)
    }

    func testMessagesKeepTheAgentFromBeingConsolidated() async throws {
        let adapter = FakeAdapter(context: 150_000)
        let (queue, _, _) = try makeQueue(adapter, consolidation: ConsolidationPolicy(idle: .milliseconds(150),
                                                                                      threshold: 100_000))
        for n in 1...4 {
            try await queue.send(message(n))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertEqual(adapter.consolidations, 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(adapter.consolidations, 1)
    }

    func testAMessageSentDuringAConsolidationWaitsForItAndDoesNotJoinIt() async throws {
        let adapter = FakeAdapter(steers: true, context: 150_000, consolidationDelay: 0.2)
        let (queue, _, _) = try makeQueue(adapter, consolidation: Self.quick)
        try await queue.send(message(1))
        try await adapter.waitForDeliveries(1)
        for _ in 0..<100 where !adapter.consolidating { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(adapter.consolidating)
        try await queue.send(message(2))
        XCTAssertEqual(adapter.steered, [])
        try await adapter.waitForDeliveries(2)
        XCTAssertEqual(adapter.maxConcurrent, 1, "the turn ran after the consolidation, not beside it")
    }

    func testAgentTurnsAlsoStartTheIdleTimer() async throws {
        let adapter = FakeAdapter(context: 150_000)
        let (queue, _, _) = try makeQueue(adapter, consolidation: Self.quick)
        try await queue.warm()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(adapter.consolidations, 0, "no turn has ended yet")
        adapter.agentTurn(TurnEnd(session: "s", outcome: .completed))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(adapter.consolidations, 1)
    }

    func testThePolicyComesFromTheRegistration() {
        func registration(idle: Int?, threshold: Int?) -> AgentRegistration {
            AgentRegistration(agent: "a", name: "A", harness: .claudeCode, executable: "", root: "/",
                              consolidateAfterIdle: idle, consolidateThreshold: threshold)
        }
        XCTAssertEqual(ConsolidationPolicy(registration: registration(idle: nil, threshold: nil)),
                       ConsolidationPolicy(idle: .seconds(15 * 60), threshold: 100_000))
        XCTAssertEqual(ConsolidationPolicy(registration: registration(idle: 30, threshold: 60_000)),
                       ConsolidationPolicy(idle: .seconds(30 * 60), threshold: 60_000))
        XCTAssertNil(ConsolidationPolicy(registration: registration(idle: 0, threshold: nil)))
    }
}

final class MessageRendererTests: XCTestCase {
    func testWrapperKeepsTheWordsVerbatimAndEscapesAttributes() {
        let message = Message(id: "m_7f3k2", agent: "claude", text: "why is </sirius> & \"this\" failing?\n```\nx < y\n```",
                              attachments: [.init(path: "/tmp/a \"b\".png", mimeType: "image/png")])
        XCTAssertEqual(MessageRenderer.render(message), """
        <sirius message="m_7f3k2" agent="claude">
        why is </sirius> & "this" failing?
        ```
        x < y
        ```

        <attachment path="/tmp/a &quot;b&quot;.png" type="image/png"/>
        </sirius message="m_7f3k2">
        \(MessageRenderer.replyNote)
        """)
    }

    func testNoAttachmentsNoBlankLine() {
        let text = MessageRenderer.render(Message(id: "m_1", agent: "codex", text: "hi"))
        XCTAssertEqual(text, "<sirius message=\"m_1\" agent=\"codex\">\nhi\n</sirius message=\"m_1\">\n\(MessageRenderer.replyNote)")
    }
}

final class FakeAdapter: Adapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [String] = []
    private var _starts: [String?] = []
    private var _startedTurns = 0
    private var running = 0
    private var _maxConcurrent = 0

    private var _stops = 0

    let turnDelay: Double
    let startDelay: Double
    let startSession: String?
    let startModel: String?
    let turnSession: String?
    let throwOn: Set<String>
    // Throws Outdated, a UserFacingError, on these.
    let outdatedOn: Set<String>
    // Takes a message into a running turn, as Codex's turn/steer does.
    let steers: Bool
    private var _steered: [String] = []
    var steered: [String] { lock.withLock { _steered } }

    // What .usage reports from open until a consolidation; nil after one.
    private var context: Int?
    let consolidationDelay: Double
    private var _consolidations = 0
    private var _consolidating = false
    var consolidations: Int { lock.withLock { _consolidations } }
    var consolidating: Bool { lock.withLock { _consolidating } }

    init(turnDelay: Double = 0, startDelay: Double = 0, startSession: String? = nil, startModel: String? = nil,
         turnSession: String? = nil, throwOn: Set<String> = [], outdatedOn: Set<String> = [],
         steers: Bool = false, context: Int? = nil, consolidationDelay: Double = 0) {
        self.context = context
        self.consolidationDelay = consolidationDelay
        self.outdatedOn = outdatedOn
        self.steers = steers
        self.turnDelay = turnDelay
        self.startDelay = startDelay
        self.startSession = startSession
        self.startModel = startModel
        self.turnSession = turnSession
        self.throwOn = throwOn
        (updates, sink) = makeUpdateStream()
    }

    let updates: AsyncStream<SessionUpdate>
    private let sink: AsyncStream<SessionUpdate>.Continuation

    var delivered: [String] { lock.withLock { _delivered } }
    var starts: [String?] { lock.withLock { _starts } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    var stops: Int { lock.withLock { _stops } }

    struct Gone: Error {}

    struct Outdated: UserFacingError {
        var userMessage: String? { "Run `claude update`, then try again." }
    }

    func open(_ request: SessionRequest) async throws -> SessionInfo {
        let context = lock.withLock { () -> Int? in
            _starts.append(request.resume)
            return self.context
        }
        if startDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000)) }
        sink.yield(.usage(contextTokens: context))
        return SessionInfo(session: startSession, model: startModel,
                           capabilities: AgentCapabilities(steer: steers, compact: true, agentTurns: true, usage: true))
    }

    func prompt(_ message: Message) async throws -> TurnEnd {
        lock.withLock {
            _startedTurns += 1
            running += 1
            _maxConcurrent = max(_maxConcurrent, running)
        }
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(nanoseconds: UInt64(turnDelay * 1_000_000_000))
        lock.withLock { _delivered.append(message.id) }
        if throwOn.contains(message.id) { throw Gone() }
        if outdatedOn.contains(message.id) { throw Outdated() }
        return TurnEnd(session: turnSession, outcome: .completed)
    }

    func agentTurn(_ end: TurnEnd) {
        sink.yield(.agentTurnEnded(end))
    }

    func steer(_ message: Message) async -> SteerResult {
        lock.withLock {
            guard steers, running > 0 else { return .notJoined }
            _steered.append(message.id)
            return .joined
        }
    }

    func close() async { lock.withLock { _stops += 1 } }

    func compact() async throws -> Consolidation? {
        let before = lock.withLock {
            _consolidating = true
            running += 1
            _maxConcurrent = max(_maxConcurrent, running)
            return context
        }
        if consolidationDelay > 0 { try await Task.sleep(nanoseconds: UInt64(consolidationDelay * 1_000_000_000)) }
        lock.withLock {
            _consolidating = false
            running -= 1
            _consolidations += 1
            context = nil
        }
        sink.yield(.usage(contextTokens: nil))
        return Consolidation(before: before, after: 9000, milliseconds: 5)
    }

    func waitForDeliveries(_ count: Int) async throws {
        for _ in 0..<500 where delivered.count < count { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(delivered.count, count)
    }

    func waitForStarted(_ count: Int) async throws {
        for _ in 0..<500 where lock.withLock({ _startedTurns }) < count { try await Task.sleep(nanoseconds: 10_000_000) }
    }
}

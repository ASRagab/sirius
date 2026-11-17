import Foundation
import SiriusCore
import SiriusProtocol

// One `muse serve` process: the shared JSON-RPC stdio transport
// (JSONRPCStdio) plus what is Muse's own (MSP, schemaVersion 1).
// That's the turn events of one session, and the
// two requests the server can send.
//
// Events are kept to one session: every turn also runs reminder child
// sessions whose turn/started and turn/completed come on the same stream
// with their own sessionId.
//
// Server requests: approval/request and userInput/request are answered with
// an empty receipt at once, and the decision follows as its own call
// (approval/decide, userInput/cancel). Under allowAll and
// --disable-request-user-input neither should arrive (§3.3); they're
// handled so a turn can never hang on one.
final class MuseServe: @unchecked Sendable {
    // What the adapter hears, for its session only.
    struct Events: Sendable {
        // A turn began: its id and the commandId that started it, which is
        // the server's own for a turn the agent started.
        var turnStarted: @Sendable (_ turnId: String, _ commandId: String?) -> Void = { _, _ in }
        // A turn ended, after its waiter (if any) was resumed.
        var turnCompleted: @Sendable (_ turnId: String, _ params: JSONValue) -> Void = { _, _ in }
        var contextUsage: @Sendable (_ usedTokens: Int?) -> Void = { _ in }
        var modelChanged: @Sendable (_ model: String) -> Void = { _ in }
        init() {}
    }

    private let transport: JSONRPCStdio

    private let lock = NSLock()
    private var session: String?
    private var events = Events()
    private var turnWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var finishedTurns: [String: JSONValue] = [:]
    // Set once, from the transport: why the connection is gone.
    private var failure: Error?
    // An aside's: what the agent says (TurnEvent), called on the reader's
    // thread in the order read, so all of a turn's events have gone before
    // its turn/completed resumes the wait. Set before launch().
    private var onEvent: (@Sendable (TurnEvent) -> Void)?
    // What the followed session's turn has said so far.
    private var said = MuseEvents()

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        transport = JSONRPCStdio(name: "muse serve", executable: executable, arguments: arguments,
                                 environment: environment, directory: directory)
        var handlers = JSONRPCStdio.Handlers()
        handlers.notification = { [weak self] method, params in self?.didNotify(method, params) }
        handlers.serverRequest = { [weak self] method, params in
            self?.answer(method, params) ?? .error(code: -32601, message: "Sirius does not handle \(method)")
        }
        handlers.failure = { [weak self] error in self?.fail(error) }
        transport.setHandlers(handlers)
    }

    var processIdentifier: Int32 { transport.processIdentifier }

    func observe(_ observer: @escaping @Sendable (String) -> Void) { transport.observe(observer) }

    func stream(to onEvent: @escaping @Sendable (TurnEvent) -> Void) {
        lock.withLock { self.onEvent = onEvent }
    }

    func launch() throws { try transport.launch() }

    // The session whose events count, and where they go. Events of any
    // other session are dropped.
    func follow(session: String, events: Events) {
        lock.withLock {
            self.session = session
            self.events = events
        }
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await transport.request(method, params)
    }

    func notify(_ method: String) throws { try transport.notify(method) }

    // Waits for turn/completed for this turn; returns its params.
    func turnCompleted(_ turnId: String) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let turn = finishedTurns.removeValue(forKey: turnId) {
                    continuation.resume(returning: turn)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    turnWaiters[turnId] = continuation
                }
            }
        }
    }

    func terminate(grace: TimeInterval = 2) async { await transport.terminate(grace: grace) }

    func firstStderrLine(within seconds: Double = 0.5) async -> String? {
        await transport.firstStderrLine(within: seconds)
    }

    // MARK: - Muse's own

    // An aside's: the events a notification about the followed session
    // makes, and at the turn's end those that end what it left open.
    private func hand(on method: String, _ params: JSONValue) {
        let (sink, events): ((@Sendable (TurnEvent) -> Void)?, [TurnEvent]) = lock.withLock {
            guard let onEvent else { return (nil, []) }
            return (onEvent, method == "turn/completed" ? said.end() : said.hear(method, params))
        }
        events.forEach { sink?($0) }
    }

    private func didNotify(_ method: String, _ params: JSONValue) {
        let (session, events) = lock.withLock { (self.session, self.events) }
        guard let session, params["sessionId"]?.string == session else { return }
        hand(on: method, params)
        switch method {
        case "turn/started":
            guard let turnId = params["turnId"]?.string else { return }
            events.turnStarted(turnId, params["commandId"]?.string)
        case "turn/completed":
            guard let turnId = params["turnId"]?.string else { return }
            let waiter: CheckedContinuation<JSONValue, Error>? = lock.withLock {
                if let waiter = turnWaiters.removeValue(forKey: turnId) { return waiter }
                finishedTurns[turnId] = params
                return nil
            }
            waiter?.resume(returning: params)
            events.turnCompleted(turnId, params)
        case "session/contextUsage":
            events.contextUsage(params["usedTokens"]?.safeInteger.map(Int.init))
        case "session/modelChanged":
            if let model = params["modelId"]?.string { events.modelChanged(model) }
        default:
            break
        }
    }

    // The receipt now; the decision as its own call once it's sent.
    private func answer(_ method: String, _ params: JSONValue) -> JSONRPCStdio.Reply {
        switch method {
        case "approval/request":
            if let decide = Self.approval(params) {
                Task { [weak self] in _ = try? await self?.request("approval/decide", decide) }
            }
            return .result(.object([:]))
        case "userInput/request":
            if let sessionId = params["sessionId"]?.string, let id = params["userInputId"]?.string {
                let cancel: JSONValue = .object([
                    "commandId": .string(MuseCommand.id()), "sessionId": .string(sessionId),
                    "userInputId": .string(id), "reason": .string("Sirius agents run without a person at the terminal"),
                ])
                Task { [weak self] in _ = try? await self?.request("userInput/cancel", cancel) }
            }
            return .result(.object([:]))
        default:
            return .error(code: -32601, message: "Sirius does not handle \(method)")
        }
    }

    // approval/decide for an approval/request: its first one-time approve
    // choice, else its first approve of any scope. Nil when it offers none,
    // and the approval waits on Muse's own timeout. Sirius runs agents
    // under allowAll, so an approval that reaches it is granted, as Claude
    // and Codex grant theirs.
    static func approval(_ params: JSONValue) -> JSONValue? {
        guard let sessionId = params["sessionId"]?.string, let approvalId = params["approvalId"]?.string,
              let requirement = params["currentRequirementId"], let choices = params["availableChoices"]?.array
        else { return nil }
        let approves = choices.filter { $0["decision"]?.string == "approved" }
        guard let choice = (approves.first { $0["scope"]?.string == "once" } ?? approves.first)?["choiceId"]?.string
        else { return nil }
        return .object([
            "commandId": .string(MuseCommand.id()), "sessionId": .string(sessionId),
            "approvalId": .string(approvalId), "choiceId": .string(choice), "requirementId": requirement,
        ])
    }

    private func fail(_ error: Error) {
        // The turn running ends here, with whatever it left open.
        hand(on: "turn/completed", .object([:]))
        let turns = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            if failure == nil { failure = error }
            defer { turnWaiters.removeAll() }
            return Array(turnWaiters.values)
        }
        for continuation in turns { continuation.resume(throwing: error) }
    }
}

typealias MuseServeError = JSONRPCStdioError

// MSP's commandId: the idempotency handle every mutating call carries, a
// UUIDv7 the client mints (the server never does).
enum MuseCommand {
    static func id(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }.joined(separator: "-")
    }
}

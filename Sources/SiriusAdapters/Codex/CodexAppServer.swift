import Foundation
import SiriusCore
import SiriusProtocol

// One `codex app-server` process: the shared JSON-RPC stdio transport
// (JSONRPCStdio) plus what is Codex's own. That's waiting on turn/completed
// per turn, and declining the rare request from the server (approvals),
// which Sirius never grants. When the process exits or its stdout closes,
// every pending request and turn wait fails; after terminate() they fail
// with CancellationError.
final class CodexAppServer: @unchecked Sendable {
    private let transport: JSONRPCStdio

    private let lock = NSLock()
    private var turnWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var finishedTurns: [String: JSONValue] = [:]
    // Set once, from the transport: why the connection is gone.
    private var failure: Error?
    // An aside's: what the agent says (TurnEvent), called on the reader's
    // thread in the order read, so all of a turn's events have gone before
    // its turn/completed resumes the wait. Set before launch().
    private var onEvent: (@Sendable (TurnEvent) -> Void)?
    // The thread whose events are handed on; another's (a subagent's) are
    // not. And what its turn has said so far.
    private var followed: String?
    private var events = CodexEvents()

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        transport = JSONRPCStdio(name: "app-server", errorLabel: "codex app-server", executable: executable,
                                 arguments: arguments, environment: environment, directory: directory)
        var handlers = JSONRPCStdio.Handlers()
        handlers.notification = { [weak self] method, params in self?.didNotify(method, params) }
        handlers.serverRequest = { method, _ in Self.answer(method) }
        handlers.failure = { [weak self] error in self?.fail(error) }
        transport.setHandlers(handlers)
    }

    var processIdentifier: Int32 { transport.processIdentifier }

    // Every line in both directions, prefixed ">> " (sent) or "<< "
    // (received). For tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        transport.observe(observer)
    }

    func stream(to onEvent: @escaping @Sendable (TurnEvent) -> Void) {
        lock.withLock { self.onEvent = onEvent }
    }

    func follow(thread: String) {
        lock.withLock { followed = thread }
    }

    func launch() throws { try transport.launch() }

    // Sends a request and waits for its result. Throws the server's error
    // as CodexAppServerError.rpc, or why the connection is gone.
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await transport.request(method, params)
    }

    func notify(_ method: String) throws { try transport.notify(method) }

    // Waits for turn/completed for this turn; returns its `turn` object.
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

    // Closes stdin, asks the process to exit, kills it if it has not within
    // `grace`, and returns once it is gone. Pending waits throw
    // CancellationError, before this returns.
    func terminate(grace: TimeInterval = 2) async { await transport.terminate(grace: grace) }

    func waitForExit() async { await transport.waitForExit() }

    // The first line of stderr once the process has exited; see
    // JSONRPCStdio.firstStderrLine.
    func firstStderrLine(within seconds: Double = 0.5) async -> String? {
        await transport.firstStderrLine(within: seconds)
    }

    // MARK: - Codex's own

    private func didNotify(_ method: String, _ params: JSONValue) {
        hand(on: method, params)
        guard method == "turn/completed", let turn = params["turn"], let turnId = turn["id"]?.string else { return }
        let waiter: CheckedContinuation<JSONValue, Error>? = lock.withLock {
            if let waiter = turnWaiters.removeValue(forKey: turnId) { return waiter }
            finishedTurns[turnId] = turn
            return nil
        }
        waiter?.resume(returning: turn)
    }

    // An aside's: the events a notification about the followed thread
    // makes, and at the turn's end those that end what it left open.
    private func hand(on method: String, _ params: JSONValue) {
        let (sink, said): ((@Sendable (TurnEvent) -> Void)?, [TurnEvent]) = lock.withLock {
            guard let onEvent else { return (nil, []) }
            if let followed, let thread = params["threadId"]?.string, thread != followed { return (nil, []) }
            return (onEvent, method == "turn/completed" ? events.end() : events.hear(method, params))
        }
        said.forEach { sink?($0) }
    }

    // Sirius never grants anything: approvals are declined, everything else
    // is refused. Under approvalPolicy never none of these should arrive.
    private static func answer(_ method: String) -> JSONRPCStdio.Reply {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return .result(.object(["decision": .string("decline")]))
        case "mcpServer/elicitation/request":
            return .result(.object(["action": .string("decline"), "content": .null, "_meta": .null]))
        default:
            return .error(code: -32601, message: "Sirius does not handle \(method)")
        }
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

// Codex's errors are the transport's: rpc, closed, exited.
typealias CodexAppServerError = JSONRPCStdioError

import Foundation
import SiriusCore
import SiriusProtocol

// Codex through `codex app-server` (architecture.md §5.2).
// One warm app-server per agent, one thread, one turn per Message. The agent
// reaches the user through sirius-mcp, configured as the MCP server "sirius"
// with its tools approved, because Codex's sandbox without network access
// refuses socket connects from the agent's shell.
//
// open:  spawn app-server in the root, initialize, then thread/start (or
//        thread/resume) with sandbox workspace-write and approvalPolicy
//        on-request; returns the thread id at once. Codex's auto reviewer
//        decides escalations, and the sandbox has network access, both set
//        at launch (CodexLaunch.arguments): if Claude gets network access,
//        Codex does too.
// prompt: turn/start with the rendered text, plus each image attachment as
//        a localImage item; the turn ends on turn/completed.
// steer: turn/steer into the running turn.
// close: close stdin, then terminate the process.
//
// Declares steer only. Sirius doesn't compact Codex yet (app-server has
// thread/compact/start), doesn't hear turns Codex starts by itself, and
// doesn't read its usage, so `updates` never yields.
//
// An aside (AsideOptions) is a second app-server on a fork of the agent's
// thread: thread/fork gives it the history under a new id, read from the
// rollout on disk, and leaves the agent's own process and thread alone,
// mid-turn included; its answer streams as item/agentMessage/delta
// (checked on 0.159.1). A fork keeps the developer instructions in its
// history whatever thread/fork is given, so the aside's instructions go
// at the head of its first turn instead. It has no sirius MCP server.
public actor CodexAdapter: Adapter {
    public nonisolated let registration: AgentRegistration
    public nonisolated let socketPath: String
    // Holds sirius, sirius-mcp and wmem: Sirius.app/Contents/Helpers.
    public nonisolated let helpersDirectory: URL
    // Given as developer instructions on every thread/start and thread/resume.
    public nonisolated let instructions: String?
    // Given to the worker agents it starts (CodexLaunch.arguments).
    public nonisolated let workerInstructions: String?
    private let aside: AsideOptions?
    // Whether the aside's instructions have gone with a turn of this thread.
    private var briefed = false

    private var server: CodexAppServer?
    private var thread: String?
    // The turn prompt() is waiting on, which steer() joins.
    private var activeTurn: String?
    // What thread/start or thread/resume reported.
    private var model: String?
    private var observer: (@Sendable (String) -> Void)?
    public nonisolated let updates: AsyncStream<SessionUpdate>
    private let updateSink: AsyncStream<SessionUpdate>.Continuation

    static let capabilities = AgentCapabilities(steer: true)

    public init(registration: AgentRegistration, socketPath: String, helpersDirectory: URL,
                instructions: String? = nil, workerInstructions: String? = nil, aside: AsideOptions? = nil) {
        self.aside = aside
        self.registration = registration
        self.socketPath = socketPath
        self.helpersDirectory = helpersDirectory
        self.instructions = instructions
        self.workerInstructions = workerInstructions
        (updates, updateSink) = makeUpdateStream()
    }

    // Every JSON-RPC line, ">> " sent or "<< " received. Takes effect at the
    // next open. Tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        self.observer = observer
    }

    // The running app-server's pid, for tests.
    var processIdentifier: Int32? { server?.processIdentifier }

    public func open(_ request: SessionRequest) async throws -> SessionInfo {
        let session = request.resume
        await close()
        let environment = ProcessInfo.processInfo.environment
        guard let executable = CodexLaunch.findExecutable(registered: registration.executable,
                                                          environment: environment) else {
            throw CodexAdapterError.codexNotFound(registration.executable)
        }
        let capabilities = await CodexProbe.shared.capabilities(executable: executable, environment: environment)
        guard !capabilities.isTooOld else { throw CodexAdapterError.tooOld(version: capabilities.version) }
        var childEnvironment = environment
        // An aside has no way to Sirius: its words are the reply.
        childEnvironment[SiriusEnvironment.socket] = aside == nil ? socketPath : nil
        // Helpers first on PATH, as for Claude, so the shell reaches wmem.
        childEnvironment["PATH"] = helpersDirectory.path + ":"
            + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let mcpHelper = helpersDirectory.appendingPathComponent("sirius-mcp").path
        let server = CodexAppServer(
            executable: URL(fileURLWithPath: executable),
            arguments: CodexLaunch.arguments(mcpHelper: mcpHelper, socketPath: socketPath,
                                             fast: registration.isFast, workers: workerInstructions,
                                             aside: aside != nil, capabilities: capabilities),
            environment: childEnvironment,
            directory: URL(fileURLWithPath: registration.root, isDirectory: true))
        if let observer { server.observe(observer) }
        if let aside { server.stream(to: aside.onEvent) }
        try server.launch()
        self.server = server
        briefed = false

        do {
            _ = try await server.request("initialize", .object([
                "clientInfo": .object(["name": .string("sirius"), "title": .string("Sirius"),
                                       "version": .string(Self.clientVersion)]),
            ]))
            try server.notify("initialized")
            let opened = try await openThread(on: server, resuming: session, fork: request.fork)
            thread = opened.id
            server.follow(thread: opened.id)
            model = opened.model ?? registration.model
            return SessionInfo(session: opened.id, model: model, effort: opened.effort ?? registration.effort,
                               capabilities: Self.capabilities)
        } catch {
            // Codex quit or refused as it started, e.g. at initialize on a
            // -c key it cannot read: say why, in its own first words.
            var why: String?
            switch error {
            case CodexAppServerError.rpc(_, _, let message): why = message
            case is CodexAppServerError: why = await server.firstStderrLine()
            default: break
            }
            await server.terminate()
            if self.server === server { self.server = nil }
            guard error is CodexAppServerError else { throw error }
            throw CodexAdapterError.startFailed(why ?? "\(error)", "\(error)")
        }
    }

    public func prompt(_ message: Message) async throws -> TurnEnd {
        guard let server, let thread else { throw CodexAdapterError.notStarted }
        var lead: String?
        if let aside, !briefed {
            lead = aside.instructions
            briefed = true
        }
        let params = Self.turnParams(thread: thread, message: message, effort: registration.effort,
                                     aside: aside != nil, lead: lead)
        let started = try await server.request("turn/start", .object(params))
        guard let turnId = started["turn"]?["id"]?.string else {
            throw CodexAdapterError.unexpectedResponse("turn/start returned no turn id")
        }
        activeTurn = turnId
        defer { if activeTurn == turnId { activeTurn = nil } }
        let turn = try await server.turnCompleted(turnId)
        switch turn["status"]?.string {
        case "completed":
            return TurnEnd(session: thread, outcome: .completed, model: model)
        case let status:
            let reason = turn["error"]?["message"]?.string ?? "turn \(status ?? "ended without a status")"
            return TurnEnd(session: thread, outcome: .failed(reason), model: model)
        }
    }

    // turn/steer (checked on 0.159.1): the message joins the
    // running turn as a userMessage the model reads at its next step, after
    // a running command finishes; one turn/completed still ends it. Codex
    // refuses with -32600 when no turn is active or another one is, as when
    // the turn has just ended: the queue then delivers it as its own turn.
    public func steer(_ message: Message) async -> SteerResult {
        guard let server, let thread, let activeTurn else { return .notJoined }
        do {
            _ = try await server.request("turn/steer", .object([
                "threadId": .string(thread),
                "expectedTurnId": .string(activeTurn),
                "input": .array(Self.input(for: message, aside: aside != nil)),
            ]))
            return .joined
        } catch {
            return .notJoined
        }
    }

    // Not declared; see the header.
    public func compact() async throws -> Consolidation? { nil }

    public func close() async {
        guard let server else { return }
        self.server = nil
        thread = nil
        model = nil
        await server.terminate()
    }

    // MARK: - Internals

    static let clientVersion = "0.1"

    private struct OpenedThread {
        var id: String
        var model: String?
        var effort: String?
    }

    // thread/start's params, and thread/resume's beside the thread id.
    static func threadParams(registration: AgentRegistration, instructions: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "cwd": .string(registration.root),
            "sandbox": .string("workspace-write"),
            "approvalPolicy": .string("on-request"),
        ]
        if let model = registration.model { params["model"] = .string(model) }
        if let instructions { params["developerInstructions"] = .string(instructions) }
        return params
    }

    // turn/start's params. Codex takes effort per turn, not per thread.
    static func turnParams(thread: String, message: Message, effort: String?, aside: Bool = false,
                           lead: String? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "threadId": .string(thread),
            "input": .array(input(for: message, aside: aside, lead: lead)),
        ]
        if let effort { params["effort"] = .string(effort) }
        return params
    }

    private func openThread(on server: CodexAppServer, resuming session: String?,
                            fork: Bool = false) async throws -> OpenedThread {
        let params = Self.threadParams(registration: registration, instructions: aside?.instructions ?? instructions)
        if let session, fork {
            // excludeTurns: the response then leaves the history out, which
            // Sirius never reads, and Codex does not warn of its
            // deprecated full hydration. A fork kept on disk can be
            // resumed should this app-server die; where Codex refuses one,
            // an ephemeral fork still carries the history.
            var forked = params
            forked["threadId"] = .string(session)
            forked["excludeTurns"] = .bool(true)
            do {
                return try opened(try await server.request("thread/fork", .object(forked)))
            } catch CodexAppServerError.rpc {
                forked["ephemeral"] = .bool(true)
                do {
                    return try opened(try await server.request("thread/fork", .object(forked)))
                } catch CodexAppServerError.rpc {
                    // No rollout to fork from: the aside starts empty.
                }
            }
        } else if let session {
            var resume = params
            resume["threadId"] = .string(session)
            do {
                return try opened(try await server.request("thread/resume", .object(resume)))
            } catch CodexAppServerError.rpc {
                // The thread is gone (deleted, or a different CODEX_HOME):
                // a stored session must not block the agent for good, so
                // start a new one. The queue persists the new id.
            }
        }
        return try opened(try await server.request("thread/start", .object(params)))
    }

    private func opened(_ result: JSONValue) throws -> OpenedThread {
        guard let id = result["thread"]?["id"]?.string else {
            throw CodexAdapterError.unexpectedResponse("no thread id")
        }
        return OpenedThread(id: id, model: result["model"]?.string, effort: result["reasoningEffort"]?.string)
    }

    // The rendered wrapper, then each image beside it as a native image the
    // model can see. The wrapper still names its path (DECIDED 2026.10.09).
    // In an aside the text is the user's words alone, after `lead` (the
    // aside's instructions) on its first turn.
    static func input(for message: Message, aside: Bool = false, lead: String? = nil) -> [JSONValue] {
        var text = aside ? MessageRenderer.renderAside(message) : MessageRenderer.render(message)
        if let lead { text = lead + "\n\n---\n\n" + text }
        var items: [JSONValue] = [.object([
            "type": .string("text"),
            "text": .string(text),
            "text_elements": .array([]),
        ])]
        for attachment in message.attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            items.append(.object(["type": .string("localImage"), "path": .string(attachment.path)]))
        }
        return items
    }
}

public enum CodexAdapterError: Error, Equatable, CustomStringConvertible {
    // Neither the registered executable, PATH nor ChatGPT.app has codex.
    case codexNotFound(String)
    case notStarted
    case unexpectedResponse(String)
    // Older than CodexCapabilities.floor.
    case tooOld(version: String?)
    // app-server quit, or answered with an error, before the thread was
    // open: the first line of its stderr or the error's message, then the
    // whole reason.
    case startFailed(String, String)

    public var description: String {
        switch self {
        case .codexNotFound(let registered):
            return "codex not found (registered: \(registered.isEmpty ? "none" : registered); PATH; ChatGPT.app)"
        case .notStarted: return "codex is not started"
        case .unexpectedResponse(let detail): return "codex app-server: \(detail)"
        case .tooOld(let version):
            return "codex \(version ?? "(version unknown)") is too old for Sirius: it needs \(CodexCapabilities.floor) or later"
        case .startFailed(let line, let reason):
            return "codex quit as it started: \(line)" + (reason == line ? "" : " (\(reason))")
        }
    }
}

extension CodexAdapterError: UserFacingError {
    // TODO(copy): copy. Generic on how to update: Codex comes from npm,
    // Homebrew, its standalone installer or ChatGPT.app, and `codex update`
    // is not in every release.
    public var userMessage: String? {
        switch self {
        case .tooOld(let version):
            return "Codex is too old for Sirius" + (version.map { " (\($0))" } ?? "") + ". Update Codex, then try again."
        case .startFailed(let line, _):
            return "Codex quit as it started: " + (line.count > 200 ? String(line.prefix(200)) + "…" : line)
        default:
            return nil
        }
    }
}

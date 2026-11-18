import Foundation
import SiriusCore
import SiriusProtocol

// Muse Code through `muse serve`. One warm host per
// agent, one session, one turn per Message. The agent reaches the user
// through sirius-mcp, given to the session as the MCP server "sirius".
//
// open:   spawn muse serve in the root (MuseLaunch), initialize, check the
//         schema and version, check the model against model/list, then
//         session/resume or session/start under allowAll; returns the
//         session id.
// prompt: turn/start; the turn ends on its turn/completed.
// steer:  turn/steer into the running turn.
// close:  terminate the host. The session is durable on disk.
//
// Declares steer, agentTurns and usage. Not compact: session/compact on
// 1.4.14 acks, then fails without a word (§3.3 item 8).
public actor MuseAdapter: Adapter {
    public nonisolated let registration: AgentRegistration
    public nonisolated let socketPath: String
    // Holds sirius and sirius-mcp: Sirius.app/Contents/Helpers.
    public nonisolated let helpersDirectory: URL
    // Given as the developer prompt of the host.
    public nonisolated let instructions: String?
    public nonisolated let updates: AsyncStream<SessionUpdate>
    private let updateSink: AsyncStream<SessionUpdate>.Continuation
    private let environment: [String: String]

    private var server: MuseServe?
    private var session: String?
    private var model: String?
    // The turn prompt() waits on, which steer() joins.
    private var activeTurn: String?
    // The commandIds of our own turn/starts: a turn/started carrying any
    // other one is a turn the agent started by itself.
    private var ownCommands: Set<String> = []
    private var agentTurns: Set<String> = []
    private var observer: (@Sendable (String) -> Void)?
    private var eventPump: Task<Void, Never>?
    private var pumpSink: AsyncStream<Event>.Continuation?
    // What the last open reported about the host, for diagnostics.
    private(set) var fingerprint: String?

    static let capabilities = AgentCapabilities(steer: true, agentTurns: true, usage: true)

    public init(registration: AgentRegistration, socketPath: String, helpersDirectory: URL,
                instructions: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.registration = registration
        self.socketPath = socketPath
        self.helpersDirectory = helpersDirectory
        self.instructions = instructions
        self.environment = environment
        (updates, updateSink) = makeUpdateStream()
    }

    // Every JSON-RPC line, ">> " sent or "<< " received. Takes effect at the
    // next open. Tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        self.observer = observer
    }

    var processIdentifier: Int32? { server?.processIdentifier }

    var launchArguments: [String] {
        MuseLaunch.arguments(model: registration.model, instructions: instructions)
    }

    public func open(_ request: SessionRequest) async throws -> SessionInfo {
        await close()
        guard let executable = MuseLaunch.findExecutable(registered: registration.executable,
                                                         environment: environment) else {
            throw MuseAdapterError.museNotFound(registration.executable)
        }
        let server = MuseServe(
            executable: URL(fileURLWithPath: executable),
            arguments: launchArguments,
            environment: MuseLaunch.environment(environment, socketPath: socketPath, helpers: helpersDirectory),
            directory: URL(fileURLWithPath: registration.root, isDirectory: true))
        if let observer { server.observe(observer) }
        try server.launch()
        self.server = server

        do {
            let initialized = try await server.request("initialize", .object([
                "clientInfo": .object(["name": .string("sirius"), "title": .string("Sirius"),
                                       "version": .string(Self.clientVersion)]),
                "capabilities": .object(["requestedCapabilities": .array([.string("sessionMcp")])]),
            ]))
            // Only after initialize has returned: an earlier one is dropped.
            try server.notify("initialized")
            try check(initialized)
            try await checkModel(on: server)
            let opened = try await openSession(on: server, resuming: request.resume)
            session = opened.id
            model = opened.model ?? registration.model
            follow(server, session: opened.id)
            return SessionInfo(session: opened.id, model: model, effort: registration.effort,
                               capabilities: Self.capabilities)
        } catch {
            var why: String?
            switch error {
            case MuseServeError.rpc(_, _, let message): why = message
            case is MuseServeError: why = await server.firstStderrLine()
            default: break
            }
            await server.terminate()
            if self.server === server { self.server = nil }
            guard error is MuseServeError else { throw error }
            throw MuseAdapterError.startFailed(why ?? "\(error)", "\(error)")
        }
    }

    public func prompt(_ message: Message) async throws -> TurnEnd {
        guard let server, let session else { throw MuseAdapterError.notStarted }
        let command = MuseCommand.id()
        ownCommands.insert(command)
        var params: [String: JSONValue] = [
            "commandId": .string(command),
            "sessionId": .string(session),
            "input": .array(Self.input(for: message)),
        ]
        if let effort = registration.effort { params["reasoningEffort"] = .string(effort) }
        let started = try await server.request("turn/start", .object(params))
        guard let turnId = started["turnId"]?.string else {
            throw MuseAdapterError.unexpectedResponse("turn/start returned no turnId")
        }
        // "steered": it joined a turn the agent had started itself, which
        // is ours to wait on now.
        agentTurns.remove(turnId)
        activeTurn = turnId
        defer { if activeTurn == turnId { activeTurn = nil } }
        let completed = try await server.turnCompleted(turnId)
        return turnEnd(completed)
    }

    public func steer(_ message: Message) async -> SteerResult {
        guard let server, let session, let activeTurn else { return .notJoined }
        do {
            _ = try await server.request("turn/steer", .object([
                "commandId": .string(MuseCommand.id()),
                "sessionId": .string(session),
                "expectedTurnId": .string(activeTurn),
                "input": .array(Self.input(for: message)),
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
        session = nil
        model = nil
        activeTurn = nil
        ownCommands.removeAll()
        agentTurns.removeAll()
        pumpSink?.finish()
        pumpSink = nil
        eventPump = nil
        await server.terminate()
    }

    // MARK: - Internals

    static let clientVersion = "0.1"

    private struct OpenedSession {
        var id: String
        var model: String?
    }

    private func check(_ initialized: JSONValue) throws {
        let version = initialized["serverInfo"]?["version"]?.string
        if MuseLaunch.isTooOld(version) { throw MuseAdapterError.tooOld(version: version) }
        let schema = initialized["schema"]?["version"]?.safeInteger
        if let schema, schema != MuseLaunch.schemaVersion { throw MuseAdapterError.unsupportedSchema(schema) }
        fingerprint = initialized["schema"]?["fingerprint"]?.string
    }

    // A model the tier doesn't include is accepted by session/start and
    // refused only at the first model call (§3.3 item 10): say so now.
    private func checkModel(on server: MuseServe) async throws {
        guard let wanted = registration.model else { return }
        guard let listed = try? await server.request("model/list", .object([:])),
              let models = listed["models"]?.array else { return }
        let ids = models.compactMap { $0["modelId"]?.string }
        guard !ids.isEmpty, !ids.contains(wanted) else { return }
        throw MuseAdapterError.modelUnavailable(wanted, available: ids)
    }

    private func sessionConfig() -> JSONValue {
        let mcpHelper = helpersDirectory.appendingPathComponent("sirius-mcp").path
        return .object(["mcpServers": MuseLaunch.mcpServers(mcpHelper: mcpHelper, socketPath: socketPath)])
    }

    private func openSession(on server: MuseServe, resuming session: String?) async throws -> OpenedSession {
        if let session {
            do {
                let resumed = try await server.request("session/resume", .object([
                    "commandId": .string(MuseCommand.id()),
                    "sessionId": .string(session),
                    "excludeItems": .bool(true),
                    "config": sessionConfig(),
                ]))
                return try opened(resumed)
            } catch MuseServeError.rpc {
                // The session is gone: a stored id must not block the agent
                // for good, so start a new one. The queue persists it.
            }
        }
        var params: [String: JSONValue] = [
            "commandId": .string(MuseCommand.id()),
            "workspaceRoot": .string(registration.root),
            "approvalMode": .string("allowAll"),
            "config": sessionConfig(),
        ]
        if let model = registration.model { params["modelId"] = .string(model) }
        return try opened(try await server.request("session/start", .object(params)))
    }

    private func opened(_ result: JSONValue) throws -> OpenedSession {
        guard let id = result["session"]?["sessionId"]?.string else {
            throw MuseAdapterError.unexpectedResponse("no sessionId")
        }
        return OpenedSession(id: id, model: result["session"]?["modelId"]?.string)
    }

    private func turnEnd(_ completed: JSONValue) -> TurnEnd {
        switch completed["terminal"]?.string {
        case "completed":
            return TurnEnd(session: session, outcome: .completed, model: model)
        case let terminal:
            let reason = completed["error"]?["message"]?.string
                ?? completed["reason"]?.string
                ?? "turn \(terminal ?? "ended without a terminal state")"
            return TurnEnd(session: session, outcome: .failed(reason), model: model)
        }
    }

    private enum Event: Sendable {
        case turnStarted(String, command: String?)
        case turnCompleted(String, JSONValue)
        case modelChanged(String)
    }

    // The server's events, back on the actor in the order they came: a
    // short agent turn's turn/completed must not overtake its turn/started.
    // Usage goes straight out.
    private func follow(_ server: MuseServe, session: String) {
        let (stream, sink) = AsyncStream<Event>.makeStream()
        var events = MuseServe.Events()
        events.turnStarted = { sink.yield(.turnStarted($0, command: $1)) }
        events.turnCompleted = { sink.yield(.turnCompleted($0, $1)) }
        events.modelChanged = { sink.yield(.modelChanged($0)) }
        let updates = updateSink
        events.contextUsage = { updates.yield(.usage(contextTokens: $0)) }
        server.follow(session: session, events: events)
        eventPump?.cancel()
        eventPump = Task { [weak self] in
            for await event in stream { await self?.handle(event, from: server) }
        }
        pumpSink?.finish()
        pumpSink = sink
    }

    private func handle(_ event: Event, from source: MuseServe) {
        guard source === server else { return }
        switch event {
        case .turnStarted(let turnId, let command): turnStarted(turnId, command: command)
        case .turnCompleted(let turnId, let params): turnCompleted(turnId, params)
        case .modelChanged(let model): self.model = model
        }
    }

    private func turnStarted(_ turnId: String, command: String?) {
        if let command, ownCommands.remove(command) != nil { return }
        guard turnId != activeTurn else { return }
        agentTurns.insert(turnId)
    }

    private func turnCompleted(_ turnId: String, _ params: JSONValue) {
        guard agentTurns.remove(turnId) != nil else { return }
        updateSink.yield(.agentTurnEnded(turnEnd(params)))
    }

    // The rendered wrapper, then each image beside it as a native image
    // the model can see. The wrapper still names its path.
    static func input(for message: Message) -> [JSONValue] {
        let text = MessageRenderer.render(message)
        var items: [JSONValue] = [.object([
            "type": .string("text"),
            "text": .string(text),
        ])]
        for attachment in message.attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            guard let data = FileManager.default.contents(atPath: attachment.path), !data.isEmpty else { continue }
            items.append(.object([
                "type": .string("image"),
                "mediaType": .string(attachment.mimeType.lowercased()),
                "base64Data": .string(data.base64EncodedString()),
            ]))
        }
        return items
    }
}

public enum MuseAdapterError: Error, Equatable, CustomStringConvertible {
    // Neither the registered executable, PATH nor ~/.local/bin has muse.
    case museNotFound(String)
    case notStarted
    case unexpectedResponse(String)
    // Older than MuseLaunch.floor.
    case tooOld(version: String?)
    // An MSP schema version Sirius doesn't speak.
    case unsupportedSchema(Int64)
    // The registered model isn't on the account's tier.
    case modelUnavailable(String, available: [String])
    // muse serve quit, or answered with an error, before the session was
    // open: the first line of its stderr or the error's message, then the
    // whole reason.
    case startFailed(String, String)

    public var description: String {
        switch self {
        case .museNotFound(let registered):
            return "muse not found (registered: \(registered.isEmpty ? "none" : registered); PATH; ~/.local/bin)"
        case .notStarted: return "muse is not started"
        case .unexpectedResponse(let detail): return "muse serve: \(detail)"
        case .tooOld(let version):
            return "muse \(version ?? "(version unknown)") is too old for Sirius: it needs \(MuseLaunch.floor) or later"
        case .unsupportedSchema(let version):
            return "muse serve speaks MSP schema \(version); Sirius speaks \(MuseLaunch.schemaVersion)"
        case .modelUnavailable(let model, let available):
            return "muse: \(model) is not on this account (available: \(available.joined(separator: ", ")))"
        case .startFailed(let line, let reason):
            return "muse quit as it started: \(line)" + (reason == line ? "" : " (\(reason))")
        }
    }
}

extension MuseAdapterError: UserFacingError {
    // TODO(copy): copy.
    public var userMessage: String? {
        switch self {
        case .museNotFound:
            return "Muse Code isn't installed. Install it from dev.meta.ai, then try again."
        case .tooOld(let version):
            return "Muse Code is too old for Sirius" + (version.map { " (\($0))" } ?? "") + ". Update Muse Code, then try again."
        case .unsupportedSchema:
            return "This Muse Code speaks a protocol Sirius doesn't know yet. Update Sirius, then try again."
        case .modelUnavailable(let model, _):
            return "\(model) isn't included in your Muse plan. Pick another model for this agent."
        case .startFailed(let line, _):
            return "Muse Code quit as it started: " + (line.count > 200 ? String(line.prefix(200)) + "…" : line)
        default:
            return nil
        }
    }
}

import SiriusProtocol

// What every harness implements, shaped after ACP's lifecycle:
// open a session, prompt it one turn at a time,
// steer and compact where the harness can, close it, and a stream of the
// updates the queue needs. The per-agent queue calls prompt one turn at a
// time, stores the session it reports in state.json, and branches on the
// capabilities open returned, never on the harness. An adapter never shows
// anything to the user and never reads the agent's answer, except an
// aside's (AsideOptions), whose turn it hands on as it streams (TurnEvent).
public protocol Adapter: AnyObject, Sendable {
    // Start the harness warm in its root, resuming `request.resume` when
    // given, with SIRIUS_SOCKET in its environment, and say what it can do.
    // ACP's initialize plus session/new, session/load or session/resume.
    // Returns as soon as the harness is ready: with the session when it has
    // named one by then (Codex names its thread at creation), so the queue
    // can persist it before the first turn can fail; nil when it only names
    // it at turn end. Opening again replaces the running session.
    func open(_ request: SessionRequest) async throws -> SessionInfo
    // One Message as a new turn; returns when the turn ends. ACP's
    // session/prompt. Returning .failed means the agent reported the turn
    // failed and is still up for the next one. Throwing means the transport
    // or the process is gone: the queue opens the agent again before the
    // next prompt.
    func prompt(_ message: Message) async throws -> TurnEnd
    // Add a Message to the turn prompt() is running, the way typing while an
    // agent works reaches it at its next step. Called only when open
    // declared `steer`. .joined when the harness took it into that turn,
    // whose end is then this message's end too; .notJoined when there is no
    // turn to join, and the queue sends it as a turn of its own.
    func steer(_ message: Message) async -> SteerResult
    // Shrink the agent's context to a short log of pointers, between turns
    // (architecture.md §5.1). Called only when open declared `compact`.
    // Returns when done; nil when the harness can't now (a turn of its own
    // is running). Throwing means the process is gone, as for prompt.
    func compact() async throws -> Consolidation?
    // End the session and the process. Safe to call when it is not running.
    // A pending prompt does not outlive it: it throws CancellationError
    // before close returns. ACP's session/cancel plus session/close.
    func close() async
    // What the queue needs to hear between calls, for the adapter's whole
    // life, across opens: context usage and turns the agent started by
    // itself. ACP's session/update, filtered. One consumer.
    var updates: AsyncStream<SessionUpdate> { get }
}

// What open asks for. Launch configuration (root, model, instructions,
// MCP) stays with the adapter, from the registration it was built with:
// Claude and Codex fix it when their process starts.
public struct SessionRequest: Equatable, Sendable {
    // The session to resume, from state.json.
    public var resume: String?
    // Open a copy of `resume` instead of the session itself: a session of
    // its own, with a new id, that starts with the other's history and
    // leaves it untouched, even while a turn runs in it (an aside,
    // AsideSession). Ignored without `resume`.
    public var fork: Bool

    public init(resume: String? = nil, fork: Bool = false) {
        self.resume = resume
        self.fork = fork
    }
}

// What makes an adapter an aside's (AsideSession): the one session whose
// prose the user reads. The adapter calls `onEvent` with what the harness
// says as the turn runs (TurnEvent), in order, and with all of a turn's
// events before prompt returns for that turn. It renders a Message as the
// user's words alone (MessageRenderer.renderAside), runs under
// `instructions` in place of the agent's own, and gives the session no way
// to reach the user through Sirius: its words are the reply.
public struct AsideOptions: Sendable {
    public var instructions: String
    public var onEvent: @Sendable (TurnEvent) -> Void

    public init(instructions: String, onEvent: @escaping @Sendable (TurnEvent) -> Void) {
        self.instructions = instructions
        self.onEvent = onEvent
    }
}

// What a harness says while a turn runs, in one shape for every harness
//. In-process, never a wire format. Text and
// reasoning are framed as the AI SDK's stream parts are: a start, pieces
// and an end, under one id. A tool call is a record, as ACP's is: announced
// once, then changed by id. The turn itself is framed by prompt: its call
// and the TurnEnd it returns.
//
// Rules an adapter holds: an id is the harness's own block or item id,
// unique within the session; several runs and tool calls may be open at
// once; and every start is followed by its end before prompt returns, also
// when the turn fails or is cut off. Codex and Muse leave a message open
// when a turn is interrupted, so the adapter ends what is still open.
public enum TurnEvent: Equatable, Sendable {
    // A model call began or ended within the turn. Only from a harness
    // that says so (Claude).
    case stepStarted
    case stepFinished

    // A run of the agent's prose. `phase` where the harness has said it by
    // then: Codex names it at the start, Muse only at the end, Claude never.
    case textStarted(id: String, phase: TextPhase?)
    case textDelta(id: String, text: String)
    case textEnded(id: String, phase: TextPhase?)

    // The model's reasoning, or the harness's summary of it.
    case reasoningStarted(id: String)
    case reasoningDelta(id: String, text: String)
    case reasoningEnded(id: String)

    case toolCall(ToolCall)
    case toolCallUpdated(id: String, ToolCallChange)

    // Something worth knowing that does not end the turn: a retry, a rate
    // limit, a warning. A failure that ends it is TurnEnd's.
    case notice(Notice)
}

// Whether a run of prose is the agent's remarks on its work or its answer.
public enum TextPhase: Equatable, Sendable {
    case commentary
    case answer
}

// ACP's tool kinds, less switch_mode.
public enum ToolKind: String, Equatable, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, other
}

// ACP's tool call statuses. Terminal: completed and failed.
public enum ToolStatus: String, Equatable, Sendable {
    case pending, inProgress, completed, failed
}

public struct ToolCall: Equatable, Sendable {
    public var id: String
    // The tool as the harness names it: "Bash", "commandExecution".
    public var name: String?
    // One line to show: the command, the path, the query. Empty when the
    // harness has not said yet (Claude, until the input has streamed).
    public var title: String
    public var kind: ToolKind
    public var status: ToolStatus
    // The tool call this one runs under: a subagent's.
    public var parent: String?

    public init(id: String, name: String? = nil, title: String = "", kind: ToolKind = .other,
                status: ToolStatus = .pending, parent: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.kind = kind
        self.status = status
        self.parent = parent
    }
}

// What changed about a tool call; nil is "as it was".
public struct ToolCallChange: Equatable, Sendable {
    public var status: ToolStatus?
    public var title: String?
    // A piece of the input as the model writes it (Claude: partial JSON).
    public var inputDelta: String?
    // A piece of the output as it arrives, and the whole of it when the
    // harness gives it only at the end.
    public var outputDelta: String?
    public var output: String?

    public init(status: ToolStatus? = nil, title: String? = nil, inputDelta: String? = nil,
                outputDelta: String? = nil, output: String? = nil) {
        self.status = status
        self.title = title
        self.inputDelta = inputDelta
        self.outputDelta = outputDelta
        self.output = output
    }
}

public struct Notice: Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable { case info, warning, error }
    public var severity: Severity
    public var text: String
    // The harness is trying again by itself.
    public var retrying: Bool

    public init(severity: Severity = .info, text: String, retrying: Bool = false) {
        self.severity = severity
        self.text = text
        self.retrying = retrying
    }
}

// What open reports: the session as far as the harness has named it, the
// model and effort, and what this harness can do.
public struct SessionInfo: Equatable, Sendable {
    // See open.
    public var session: String?
    // The model id the harness reports, else the one requested; nil when
    // the harness has not said yet and none was requested (Claude names it
    // with the first turn).
    public var model: String?
    public var effort: String?
    public var capabilities: AgentCapabilities

    public init(session: String? = nil, model: String? = nil, effort: String? = nil,
                capabilities: AgentCapabilities = AgentCapabilities()) {
        self.session = session
        self.model = model
        self.effort = effort
        self.capabilities = capabilities
    }
}

// What a harness can do beyond open, prompt and close. Everything is off
// unless the adapter declares it.
public struct AgentCapabilities: Equatable, Sendable {
    // Joins a running turn, and says whether it did (steer).
    public var steer: Bool
    // Compacts its context when Sirius asks (compact).
    public var compact: Bool
    // Starts turns by itself and reports their ends (.agentTurnEnded).
    public var agentTurns: Bool
    // Reports its context size (.usage).
    public var usage: Bool

    public init(steer: Bool = false, compact: Bool = false, agentTurns: Bool = false, usage: Bool = false) {
        self.steer = steer
        self.compact = compact
        self.agentTurns = agentTurns
        self.usage = usage
    }
}

public enum SteerResult: Equatable, Sendable {
    case joined
    case notJoined
}

public enum SessionUpdate: Equatable, Sendable {
    // The agent's context in tokens as of its last model call; nil when the
    // harness no longer knows (just opened, or just compacted).
    case usage(contextTokens: Int?)
    // A turn the agent started by itself ended, e.g. when a background task
    // it launched finished.
    case agentTurnEnded(TurnEnd)
}

// For adapters: the stream they return as `updates`, and its sink. Keeps
// the newest updates when nobody reads them (the first-turn adapter).
public func makeUpdateStream() -> (AsyncStream<SessionUpdate>, AsyncStream<SessionUpdate>.Continuation) {
    let (stream, continuation) = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
    return (stream, continuation)
}

// What a consolidation did: the context in tokens before and after, as far
// as the harness said, and how long it took.
public struct Consolidation: Equatable, Sendable {
    public var before: Int?
    public var after: Int?
    public var milliseconds: Int
    public var outcome: TurnEnd.Outcome

    public init(before: Int?, after: Int?, milliseconds: Int, outcome: TurnEnd.Outcome = .completed) {
        self.before = before
        self.after = after
        self.milliseconds = milliseconds
        self.outcome = outcome
    }
}

// When the queue consolidates an agent: after `idle` with no turn, once its
// context is at least `threshold` tokens.
public struct ConsolidationPolicy: Equatable, Sendable {
    public static let defaultIdleMinutes = 15
    public static let defaultThreshold = 100_000

    public var idle: Duration
    public var threshold: Int

    public init(idle: Duration, threshold: Int) {
        self.idle = idle
        self.threshold = threshold
    }

    // The registration's consolidate_after_idle and consolidate_threshold,
    // or the defaults; nil when it turns consolidation off (0 minutes).
    public init?(registration: AgentRegistration) {
        let minutes = registration.consolidateAfterIdle ?? Self.defaultIdleMinutes
        guard minutes > 0 else { return nil }
        self.init(idle: .seconds(minutes * 60),
                  threshold: max(0, registration.consolidateThreshold ?? Self.defaultThreshold))
    }
}

public struct TurnEnd: Equatable, Sendable {
    // The resume id after this turn. Absent when the turn failed before the
    // agent reported one.
    public var session: String?
    public var outcome: Outcome
    // The model id that ran the turn, as the harness reports it.
    public var model: String?

    public enum Outcome: Equatable, Sendable {
        case completed
        // The agent reported an error or its process exited mid-turn.
        case failed(String)
    }

    public init(session: String?, outcome: Outcome, model: String? = nil) {
        self.session = session
        self.outcome = outcome
        self.model = model
    }
}

// An adapter error the user can act on as it stands ("run claude update"):
// the queue and the host show `userMessage` as a toast under the agent's
// mark instead of the bare reason. Nil for errors with nothing to say.
public protocol UserFacingError: Error {
    var userMessage: String? { get }
}

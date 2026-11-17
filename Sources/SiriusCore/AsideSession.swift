import Foundation
import SiriusProtocol

// One aside: a conversation on one point, held beside the agent's main one.
// It is a fork of the agent's session, so it
// starts knowing everything the agent knew, and from there it is its own:
// what is said here never reaches the main session, and a turn here neither
// waits for the main queue nor holds it up.
//
// It is also the one place the user reads the agent's own words. The
// adapter is built for it (AsideOptions) and hands on the answer as the
// harness streams it; `events` carries those pieces, then the turn's end,
// in the order they happened.
//
// send() queues a turn and returns; turns run one at a time in the order
// sent. The harness starts on warm() or the first send. A turn that loses
// the harness is reported as failed, and the next one starts it again: on
// the aside's own session once it has one, else on a new fork.
//
// close() ends the harness. The session stays on disk, with the harness,
// and `transcript` is what was said, for the pointer the main session gets.
public actor AsideSession {
    public enum Event: Equatable, Sendable {
        // What the turn running says, as it says it: its prose, its
        // reasoning, its tool calls.
        case event(TurnEvent)
        // The turn running ended; with why, when it failed.
        case turnEnded(failure: String?)
    }

    public struct Turn: Equatable, Sendable {
        public enum Role: String, Equatable, Sendable { case user, agent }
        public var role: Role
        public var text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public nonisolated let id: String
    public nonisolated let agent: String
    public nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let adapter: any Adapter
    // The agent's session as it was when the aside opened; nil when the
    // agent had none yet, and the aside then starts empty.
    private let parent: String?

    private var pending: [Message] = []
    private var pump: Task<Void, Never>?
    private var startup: Task<Result<SessionInfo, any Error>, Never>?
    private var opened = false
    private var closed = false
    // The aside's own session, once the harness has named it.
    public private(set) var session: String?
    public private(set) var transcript: [Turn] = []
    // The answer to the turn running, as far as it has come.
    private let answer: Answer

    // `makeAdapter` gets the options the aside's adapter must be built
    // with, `onEvent` already tied to `events`.
    public init(id: String = AsideSession.makeID(), agent: String, parent: String?,
                instructions: String = AsidePrompts.instructions,
                makeAdapter: (AsideOptions) -> any Adapter) {
        self.id = id
        self.agent = agent
        self.parent = parent
        let (events, sink) = AsyncStream<Event>.makeStream()
        self.events = events
        self.sink = sink
        let answer = Answer()
        self.answer = answer
        adapter = makeAdapter(AsideOptions(instructions: instructions, onEvent: { event in
            answer.hear(event)
            sink.yield(.event(event))
        }))
    }

    public static func makeID() -> String {
        "a_" + MessageID.make().dropFirst(2)
    }

    // Starts the harness before the first turn, so that turn skips the
    // start. A failure is left for the first turn to find and report.
    public func warm() async {
        guard !closed, !opened else { return }
        _ = await ensureOpen()
    }

    // Queues `text` as the next turn. Returns at once.
    public func send(_ text: String, attachments: [Message.Attachment] = [], context: Message.Context? = nil) {
        guard !closed else { return }
        pending.append(Message(id: MessageID.make(), agent: agent, text: text, attachments: attachments,
                               context: context))
        if pump == nil { pump = Task { await self.drain() } }
    }

    // Whether a turn is running or waiting.
    public var isBusy: Bool { pump != nil }

    // Ends the aside: no further turns, the harness stopped, `events`
    // finished. A turn cut off keeps what it had said.
    public func close() async {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        pump?.cancel()
        await adapter.close()
        await pump?.value
        if let startup {
            _ = await startup.value
            await adapter.close()
        }
        sink.finish()
    }

    private func drain() async {
        while !closed, !pending.isEmpty {
            await run(pending.removeFirst())
        }
        pump = nil
    }

    private func run(_ message: Message) async {
        transcript.append(Turn(role: .user, text: message.text))
        _ = answer.take()
        var failure: String?
        do {
            if case .failure(let error) = await ensureOpen() { throw error }
            let end = try await adapter.prompt(message)
            if let named = end.session { session = named }
            if case .failed(let reason) = end.outcome { failure = reason }
        } catch is CancellationError {
            failure = closed ? nil : "stopped"
        } catch {
            // The harness is gone: the next turn starts it again.
            opened = false
            await adapter.close()
            failure = (error as? UserFacingError)?.userMessage ?? "\(error)"
        }
        // All of the turn's events are in by now (AsideOptions.onEvent).
        let said = answer.take()
        if !said.isEmpty { transcript.append(Turn(role: .agent, text: said)) }
        if !closed { sink.yield(.turnEnded(failure: failure)) }
    }

    // What the adapter has said of the turn running: its runs of prose in
    // the order they began. `onEvent` is called on the adapter's executor,
    // not this actor's, hence the lock.
    private final class Answer: @unchecked Sendable {
        private struct Run {
            var id: String
            var text = ""
            var commentary: Bool
        }

        private let lock = NSLock()
        private var runs: [Run] = []

        func hear(_ event: TurnEvent) {
            lock.withLock {
                switch event {
                case .textStarted(let id, let phase):
                    runs.append(Run(id: id, commentary: phase == .commentary))
                case .textDelta(let id, let text):
                    if let at = runs.lastIndex(where: { $0.id == id }) {
                        runs[at].text += text
                    } else {
                        runs.append(Run(id: id, text: text, commentary: false))
                    }
                case .textEnded(let id, let phase):
                    if let phase, let at = runs.lastIndex(where: { $0.id == id }) {
                        runs[at].commentary = phase == .commentary
                    }
                default:
                    break
                }
            }
        }

        // The answer: each run a paragraph of its own, the agent's remarks
        // on its work left out.
        func take() -> String {
            lock.withLock {
                defer { runs = [] }
                return runs.filter { !$0.commentary && !$0.text.isEmpty }.map(\.text).joined(separator: "\n\n")
            }
        }
    }

    private func ensureOpen() async -> Result<Void, any Error> {
        if opened { return .success(()) }
        if let startup { return await startup.value.map { _ in () } }
        let adapter = adapter
        // Its own session when a turn has named one; else a new fork.
        let request = session.map { SessionRequest(resume: $0) }
            ?? SessionRequest(resume: parent, fork: parent != nil)
        let task = Task { () -> Result<SessionInfo, any Error> in
            do { return .success(try await adapter.open(request)) } catch { return .failure(error) }
        }
        startup = task
        let result = await task.value
        startup = nil
        switch result {
        case .success(let info):
            if closed {
                await adapter.close()
                return .failure(CancellationError())
            }
            if let named = info.session, !(request.fork && named == parent) { session = named }
            opened = true
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }
}

// What an aside's session is told (AsideOptions.instructions) and how its
// first turn is put when the agent opened it.
public enum AsidePrompts {
    // TODO(copy): the wording.
    public static let instructions = """
        # Sirius aside

        This session is an aside: a side conversation the user opened in a window next to their work, forked from your conversation with them in Sirius. You have that whole conversation as context. It goes on without you; nothing said here reaches it.

        Everything above about replying through `sirius` commands or Sirius tools, about acks, about keeping turns short and about handing work to background agents applied to that conversation, not to this one. Here it is the reverse:

        - Your plain text is the reply. The user reads it in the window as you write it.
        - Do not send toasts, notifications or speech, and do not call `sirius` or any Sirius tool. They are not available here.
        - Write as you would in a chat: answer first, then what supports it. Use Markdown where it helps (short headings, lists, `code`, fenced code blocks). No preamble and no sign-off.
        - Take the room the question needs. This window exists for answers too long for a toast and for back-and-forth, so be complete, and ask when you need to.
        - You may read files, search and run commands yourself to answer well. When the user asks you to change something, do it and say what you did.

        If the last thing in your history is a tool call that looks cut off, that is only where the fork was taken. Ignore it and do not mention it.
        """

    // The first turn of an aside the agent opened with `display aside`:
    // the user typed nothing here, so the agent's brief stands in. The
    // fork already holds the user's message.
    public static func opened(brief: String) -> String {
        """
        [Sirius: you opened this aside from the main conversation instead of answering there, with this brief: "\(brief)". The user sees none of this note. Answer their last message here now, in full.]
        """
    }

    // The line the main session gets once an aside has closed
    // (AgentTurnQueue.note): what it was about and where it is kept.
    public static func closedNote(topic: String, turns: Int, transcript: String?) -> String {
        var note = "the user had an aside with you, a side conversation forked from this one, about \"\(topic)\" (\(turns) \(turns == 1 ? "exchange" : "exchanges"), now closed). It is not in your context."
        if let transcript { note += " If they refer to it, read \(transcript)." }
        return note
    }

    // The first line of what opened the aside, shortened, as its topic.
    public static func topic(of text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}

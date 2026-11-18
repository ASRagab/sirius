import AppKit
import ParrotCore
import SiriusCore
import SiriusProtocol

// The agents dictation can address, as the composer's target last listed
// them. Read again at each press and each composer open, so an agent
// registered since is addressable by the time its transcript arrives.
@MainActor
final class DictationAgents {
    private let target: ComposerTarget
    private(set) var agents: [ComposerAgent] = []

    init(target: ComposerTarget) {
        self.target = target
    }

    var addresses: [DictationAddress] {
        agents.map { DictationAddress.forAgent(id: $0.id, name: $0.name) }
    }

    // The display names, for the transcription's vocabulary.
    var names: [String] { agents.map(\.name) }

    func set(_ agents: [ComposerAgent]) {
        self.agents = agents
    }

    func refresh() {
        Task { set(await target.composerAgents()) }
    }
}

// Where a dictated transcript goes once ParrotCore's loop has it: into the
// open composer at its caret; for a paste hold (⌃fn), at the cursor of the
// frontmost app through ParrotCore's CursorDelivery, as Parrot pastes;
// otherwise to an agent as a message, the named one or the composer's
// selected agent. The choice is SiriusCore's DictationDestination,
// which is tested. A message goes through the same send as the composer's,
// so the host logs it as any message; the log here has counts only, and
// text pasted at the cursor is never logged or kept.
@MainActor
final class SiriusDelivery: TranscriptDelivery {
    private let composer: ComposerController
    private let target: ComposerTarget
    private let agents: @MainActor () -> [DictationAddress]
    // Parrot's paste: the clipboard borrowed for a ⌘V and restored 0.25 s
    // later; nothing at all in a password field, and the transcript left on
    // the clipboard if focus moved since the press.
    private let cursor = CursorDelivery()
    // The mode of the hold whose transcript arrives next, set by
    // DictationService at each release. A transcription still running when
    // the next hold is released takes that hold's mode, as the surface
    // takes that hold's route.
    var mode: DictationMode = .agent
    // Reads the app in front, as the composer does at each open. Replaced
    // in tests.
    var readContext: (_ pid: Int32, _ bundleID: String) async -> AmbientSnapshot? = { pid, bundleID in
        await FrontAppContext.read(pid: pid, bundleID: bundleID)
    }

    init(composer: ComposerController, target: ComposerTarget,
         agents: @escaping @MainActor () -> [DictationAddress]) {
        self.composer = composer
        self.target = target
        self.agents = agents
    }

    // Throws what the cursor or the send throws, which closes the pill
    // (dictationFailed). An empty body ("Codex," alone) or an empty paste is
    // dropped without a failure.
    func deliver(_ text: String, focusAtStart: FocusSnapshot?) async throws {
        let destination = DictationDestination.of(
            text,
            mode: mode,
            composerOpen: composer.isOpen,
            composerFocused: composer.isFocused,
            selected: composer.currentAgent,
            agents: agents()
        )
        switch destination {
        case .composer(let text):
            SiriusLog.dictation.info("dictation: \(text.count) chars into the composer")
            composer.insertDictation(text)
        case .cursor(let text):
            SiriusLog.dictation.info("dictation: \(text.count) chars to the cursor")
            do {
                try await cursor.deliver(text, focusAtStart: focusAtStart)
            } catch {
                SiriusLog.dictation.error("dictation: paste at the cursor failed: \(error)")
                throw error
            }
        case .agent(let agent, let body):
            SiriusLog.dictation.info("dictation: \(body.count) chars to \(agent)")
            do {
                let front = await frontContext(for: agent, body: body)
                // Held in the composer, behind the warning.
                if front.held { return }
                let context = front.context
                try await target.send(text: body, attachments: [], context: context, to: agent)
            } catch {
                SiriusLog.dictation.error("dictation: send to \(agent) failed: \(error)")
                NSSound.beep()
                throw error
            }
        case .nothing:
            SiriusLog.dictation.info("dictation: nothing to deliver")
        }
    }

    // What the app in front has open and selected as the transcript
    // arrives, to go with a spoken message as it goes with a typed one.
    // Read after the transcription, not at the press: the app in front then
    // is the one asked. Nil when the setting is off, Sirius is in front, or
    // the app does not answer in time.
    // Says something to the user under an agent's mark (a toast). Set by
    // main; nothing in the tests.
    var notice: @MainActor (_ agent: String, _ text: String) -> Void = { _, _ in }

    private func frontContext(for agent: String, body: String) async -> (context: Message.Context?, held: Bool) {
        guard SettingsKeys.ambientContextEnabled(in: .standard),
              let front = NSWorkspace.shared.frontmostApplication, front != .current,
              let bundleID = front.bundleIdentifier
        else { return (nil, false) }
        let snapshot = await readContext(front.processIdentifier, bundleID)
        // A spoken message has no composer to warn in, so one over an app
        // marked sensitive opens the composer with the words in it and the
        // warning showing (confirmSpoken). When the composer is already up
        // with a draft, the context is left out, and said to be.
        if let snapshot, ContextWarnings.shouldWarn(bundleID, declared: snapshot.tree.sensitive, in: .standard) {
            if composer.confirmSpoken(body, to: agent) {
                SiriusLog.dictation.info("dictation: held in the composer, warning before context from \(bundleID)")
                return (nil, true)
            }
            let app = front.localizedName ?? snapshot.appName ?? "that app"
            // TODO(copy): copy
            notice(agent, "Left out what you had selected in \(app). Send it from the composer, or stop this warning in Settings.")
            SiriusLog.dictation.info("dictation: context from \(bundleID) left out, sensitive")
            return (nil, false)
        }
        let context = snapshot?.messageContext
        // Counts only: what was selected is never logged.
        let via = snapshot?.helper.map { " via helper \($0)" } ?? ""
        SiriusLog.dictation.info("dictation: context from \(bundleID)\(via): \(context?.items.count ?? 0) items")
        return (context, false)
    }
}

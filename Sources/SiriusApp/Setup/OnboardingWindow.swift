import AppKit
import Combine
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The first-run onboarding: one sheet over the night sky (NightSky),
// modeled on Parrot's (parrot Sources/ParrotApp/UI/OnboardingWindow.swift).
// It shows the two shortcuts, Microphone and Accessibility
// each with its own Allow, and the agents' folders, then Get Started, which
// waits for both grants and an agent with a folder.
//
// Each new agent's folder is the one its harness most recently used among
// those it already trusts (TrustedFolders); the sheet says so
// in one line. Its Change, or Choose when no trusted folder was found,
// swaps the sheet for the agents (OnboardingPane): a list, then one agent
// in focus with its folder, in the same window.
//
// Opens at launch while Onboarding.showsWindow says so: no agent registered,
// or never been through. "Settings…" opens the Settings window instead
// (SettingsWindow); the debug menu's Onboarding still opens this.
// Get Started writes the agents, starting them, and the window dissolves;
// Esc and ⌘W close it at once. Each counts as done; quitting with it open
// does not. The speech model downloads at launch, out of sight
// (DictationService); the onboarding never shows it.
@MainActor
final class OnboardingWindow {
    // The window's fixed size.
    static let size = NSSize(width: 480, height: 580)
    // The composer's corner. Kept over the system's smaller one.
    static let radius: CGFloat = 32
    // The system's hairline for a dark window, drawn at that corner: the
    // composer's #171719 rim vanished against the sky.
    static let hairline = NSColor(white: 1, alpha: 0.16)
    // Get Started: the window dissolves.
    static let dissolve: TimeInterval = 0.6

    private let registry: AgentRegistry
    private let detector: AgentDetector
    private let trustedFolders: TrustedFolders
    private let shortcuts: ShortcutsModel
    private let defaults: UserDefaults
    private let onSave: () -> Void
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var keys: OnboardingKeys?
    private var finishing = false
    private lazy var delegate = Delegate(owner: self)

    init(registry: AgentRegistry, shortcuts: ShortcutsModel,
         detector: AgentDetector = AgentDetector(), trustedFolders: TrustedFolders = TrustedFolders(),
         defaults: UserDefaults = .standard, onSave: @escaping () -> Void) {
        self.registry = registry
        self.shortcuts = shortcuts
        self.detector = detector
        self.trustedFolders = trustedFolders
        self.defaults = defaults
        self.onSave = onSave
    }

    var completed: Bool { defaults.bool(forKey: Onboarding.completedKey) }

    // At launch: opens when Onboarding.showsWindow says so, and returns
    // whether it did.
    @discardableResult
    func showIfNeeded() -> Bool {
        let hasAgents = !registry.loadAll().agents.isEmpty
        guard Onboarding.showsWindow(hasAgents: hasAgents, completed: completed) else { return false }
        SiriusLog.onboarding.info("showing the onboarding")
        // Once the run loop is up, so activation brings the window forward.
        DispatchQueue.main.async { self.show() }
        return true
    }

    // Opens the sheet, or brings it forward; with `agents`, as "Settings…"
    // does, at the agents list.
    func show(agents: Bool = false) {
        if let window, let model {
            if agents { model.pane = .agents }
            bringForward(window)
            return
        }
        let model = makeModel(pane: agents ? .agents : .sheet)
        self.model = model
        let window = OnboardingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = Self.surface(around: OnboardingView(model: model))
        window.title = "Welcome to Sirius" // TODO(copy): copy
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()
        model.window = window
        self.window = window
        keys = OnboardingKeys(window: window, model: model)

        model.grants.start()
        for agent in model.agents { agent.detect() }
        bringForward(window)
    }

    // The window's content: the composer's surface (installComposerSurface)
    // with the night sky over its glass and the sheet on that. The window
    // keeps the composer's light appearance for its shadow's rim
    // (applyComposerWindowShadow); the sheet is dark, so its controls draw
    // for the dark surface.
    //
    // The sky is opaque, so the blur no longer shows through; the surface
    // still gives the rounded corner, its 1 pt rim (a layer border, drawn
    // above the sky, in the system's hairline rather than the composer's)
    // and the shape the shadow follows. The sky has its own hosting view,
    // so the sheet's changes never draw it again.
    static func surface(around page: OnboardingView) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        installComposerSurface(in: container, radius: radius)
        container.layer?.borderColor = hairline.cgColor
        let sky = NSHostingView(rootView: NightSky())
        sky.sizingOptions = []
        sky.frame = container.bounds
        sky.autoresizingMask = [.width, .height]
        container.addSubview(sky)
        let hosting = NSHostingView(rootView: page)
        // Keep the window its fixed size whatever the sheet asks for.
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(hosting)
        return container
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app's activation can be refused; the window still
        // comes forward, as Parrot's does.
        window.orderFrontRegardless()
        // The shadow is taken from the content's alpha; once the rounded
        // surface has drawn, so it follows the 32 pt corner.
        window.displayIfNeeded()
        window.invalidateShadow()
        DispatchQueue.main.async { window.invalidateShadow() }
    }

    private func makeModel(pane: OnboardingPane) -> OnboardingModel {
        let existing = registry.loadAll().agents.map(\.registration)
        // Only a new agent is offered its harness's folder, and only the
        // most recently used one is kept.
        let trustedFolders = trustedFolders
        let agents = AgentChoice.choices(existing: existing, detector: detector) {
            trustedFolders.folders(for: $0).first
        }
        let offered = agents.filter { $0.trusted != nil }.count
        SiriusLog.onboarding.info("onboarding: \(offered) agent(s) offered a trusted folder")
        let model = OnboardingModel(agents: agents, shortcuts: shortcuts,
                                    requiresGrants: !completed, pane: pane)
        model.getStarted = { [weak self] in
            guard let self, self.saveAgents(agents) else { return }
            self.finish()
        }
        model.close = { [weak self] in self?.window?.performClose(nil) }
        return model
    }

    // Done, and the window dissolves over 0.6 s.
    private func finish() {
        guard let window, !finishing else { return }
        finishing = true
        // A recording still running would keep the compose shortcut set aside.
        shortcuts.cancelRecording()
        defaults.set(true, forKey: Onboarding.completedKey)
        SiriusLog.onboarding.info("onboarding done")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.dissolve
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.close() }
        })
    }

    // Writes each chosen agent; one left off keeps whatever is registered.
    // Then the host reloads, starting the agents warm. False, with an alert,
    // when one could not be written.
    private func saveAgents(_ agents: [AgentChoice]) -> Bool {
        var failures: [String] = []
        for agent in agents {
            guard let registration = agent.registration else { continue }
            do {
                try registry.register(registration)
                agent.saved(registration)
            } catch {
                failures.append("\(registration.name): \(error)")
            }
        }
        guard failures.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the agents" // TODO(copy): copy
            alert.informativeText = failures.joined(separator: "\n")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
        onSave()
        return true
    }

    // Closing by hand counts as done, as Parrot's.
    fileprivate func closedByUser() {
        if !completed { defaults.set(true, forKey: Onboarding.completedKey) }
    }

    fileprivate func closed() {
        shortcuts.cancelRecording()
        model?.grants.stop()
        finishing = false
        keys = nil
        model = nil
        window = nil
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        private weak var owner: OnboardingWindow?

        init(owner: OnboardingWindow) { self.owner = owner }

        // Asked only for a close by hand (OnboardingPanel.performClose), not
        // for `close()` from Get Started or for quitting.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { owner?.closedByUser() }
            return true
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { owner?.closed() }
        }
    }
}

// The onboarding's window: borderless, as the composer, so the surface is
// all there is. A borderless window is neither key nor closable by itself:
// it takes keys, for the sheet's keys (OnboardingKeys), the shortcut
// recording and the folder pills, and closes by hand from Esc or ⌘W, asking
// its delegate first as the system close button would.
private final class OnboardingPanel: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        applyComposerWindowShadow(to: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    // The system's performClose beeps without a close button.
    override func performClose(_ sender: Any?) {
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        close()
    }

    // ⌘W, which an accessory app's missing File menu would otherwise not
    // send.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// The sheet's keys, wherever the focus is in the window: Return and Enter
// press Get Started on the sheet when it takes a click, and Esc goes back a
// pane (an agent to the list, the list to the sheet) or, on the sheet,
// closes the window by hand. A local monitor rather than the sheet's shortcuts, so a focused
// control never takes them first; an alert or the folder panel is another
// window and keeps its own.
@MainActor
final class OnboardingKeys {
    enum Key: Equatable {
        case getStarted, close
    }

    // Set once, on the main thread; removed as it goes.
    private nonisolated(unsafe) var monitor: Any?

    init(window: NSWindow, model: OnboardingModel) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak model] event in
            guard event.window === window, let key = Self.key(for: event) else { return event }
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                // A shortcut being recorded takes every key, Esc included.
                guard let model, !model.shortcuts.isRecording else { return false }
                switch key {
                case .getStarted:
                    if model.pane == .sheet, model.canGetStarted { model.getStarted() }
                case .close:
                    model.back()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // Return, Enter and Esc, with no modifier.
    nonisolated static func key(for event: NSEvent) -> Key? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return nil }
        return key(code: event.keyCode)
    }

    nonisolated static func key(code: UInt16) -> Key? {
        switch code {
        case 36, 76: .getStarted // Return, Enter
        case 53: .close // Esc
        default: nil
        }
    }
}

// What the window shows: the sheet, the agents list (from Change or Choose
// on the folders line, or "Settings…"), or one agent in focus, after the
// list-then-focus design of the Settings window.
enum OnboardingPane: Hashable {
    case sheet
    case agents
    case agent(AgentRegistration.Harness)
}

// The agents, the grants, the shortcuts, and the sheet's actions.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var pane: OnboardingPane
    let agents: [AgentChoice]
    let shortcuts: ShortcutsModel
    let grants = GrantsModel()
    // The first time through, Get Started waits for the grants; opened
    // again from Settings…, not.
    let requiresGrants: Bool
    weak var window: NSWindow?

    // Writes the agents, and the window dissolves.
    var getStarted: () -> Void = {}
    // Esc: the window closes by hand.
    var close: () -> Void = {}

    private var forwarding: [AnyCancellable] = []

    init(agents: [AgentChoice], shortcuts: ShortcutsModel, requiresGrants: Bool = true,
         pane: OnboardingPane = .sheet) {
        self.agents = agents
        self.shortcuts = shortcuts
        self.requiresGrants = requiresGrants
        self.pane = pane
        // The sheet re-renders as any agent, grant or shortcut changes.
        let children = agents.map(\.objectWillChange) + [grants.objectWillChange, shortcuts.objectWillChange]
        forwarding = children.map { $0.sink { [weak self] _ in self?.objectWillChange.send() } }
    }

    var agentsChosen: Int { agents.filter { $0.registration != nil }.count }

    // Esc and "‹ Agents": back a pane; from the sheet, the window closes.
    func back() {
        switch pane {
        case .agent: pane = .agents
        case .agents: pane = .sheet
        case .sheet: close()
        }
    }

    func agent(_ harness: AgentRegistration.Harness) -> AgentChoice? {
        agents.first { $0.harness == harness }
    }

    // The agents in the list's order: ChatGPT / Codex first, as the agents
    // step had them.
    var ordered: [AgentChoice] {
        agents.sorted { ($0.harness == .codex ? 0 : 1) < ($1.harness == .codex ? 0 : 1) }
    }

    var canGetStarted: Bool {
        Onboarding.canGetStarted(grants: grants.state, agentsChosen: agentsChosen, requiresGrants: requiresGrants)
    }

    // The agents working in a folder their harness trusts.
    var trustedAgents: [AgentChoice] { agents.filter(\.usesTrusted) }

    // The folders line: the trusted folders in use while every agent with
    // a folder has its harness's trusted one; otherwise the folders chosen,
    // or a request to choose one.
    var foldersLine: String {
        let chosen = agents.filter { $0.registration != nil || $0.usesTrusted }
        let trusted = trustedAgents
        if !trusted.isEmpty, trusted.count == chosen.count,
           let line = Onboarding.foldersLine(count: Set(trusted.compactMap(\.root)).count) {
            return line
        }
        return Onboarding.chosenFoldersLine(count: Set(chosen.compactMap(\.root)).count)
    }

    // The line's link: Change once there is a folder, Choose before.
    var foldersAction: String {
        agentsChosen > 0 || !trustedAgents.isEmpty ? "Change" : "Choose" // TODO(copy): copy
    }

    // The folders, one per line, for the line's tooltip.
    var foldersHelp: String {
        trustedAgents.compactMap { agent in
            agent.root.map { "\(agent.name): \(($0 as NSString).abbreviatingWithTildeInPath)" }
        }.joined(separator: "\n")
    }
}

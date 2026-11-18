import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol

// One harness on the onboarding sheet: whether its CLI was found, whether
// it is on, and its folder, never the home folder. A new agent's folder is
// the one its harness most recently used among those it already trusts
// (TrustedFolders), so no folder needs choosing; without one
// the sheet asks for it. Moved from SetupWindow's SetupRow when the
// onboarding replaced it; the rules are setup's.
@MainActor
final class AgentChoice: ObservableObject, Identifiable {
    let harness: AgentRegistration.Harness
    nonisolated var id: String { harness.rawValue }

    // Nil while the shell lookup runs; then found or not.
    @Published private(set) var executable: String?
    @Published private(set) var looking = true
    @Published var isOn: Bool
    @Published private(set) var root: String?
    // The rest of agent.json that the Settings window edits: the model and
    // effort in the harness's words, and fast mode. Nil: the user's own
    // default for that harness.
    @Published var model: String?
    @Published var effort: String?
    @Published var fast: Bool
    // Whether Sirius runs the agent (agent.json's `enabled`). Off keeps
    // its registration, folder and session.
    @Published var enabled: Bool

    // The harness's own most recently used trusted folder, offered to a
    // new agent; nil for one already registered, which keeps its folder.
    let trusted: String?

    // What agent.json holds for it, or nil before it is registered; set
    // again once Settings writes it (saved()).
    private(set) var current: AgentRegistration?
    private let detector: AgentDetector

    init(harness: AgentRegistration.Harness, current: AgentRegistration?, detector: AgentDetector,
         trusted: String? = nil) {
        self.harness = harness
        self.current = current
        self.detector = detector
        self.trusted = current == nil ? trusted : nil
        root = current?.root ?? self.trusted
        isOn = current != nil
        model = current?.model
        effort = current == nil ? Self.defaultEffort(harness) : current?.effort
        fast = current?.isFast ?? AgentRegistration.defaultFast(harness)
        enabled = current?.isEnabled ?? true
    }

    // Registered: agent.json exists for it.
    var isRegistered: Bool { current != nil }

    // Whether the agent works in the folder its harness trusts, as far as is
    // known: still so while the CLI is looked for, and not once it is found
    // missing or another folder is chosen.
    var usesTrusted: Bool {
        guard let trusted, root == trusted else { return false }
        return looking || executable != nil
    }

    // The harness's product name, as the folders line says whose trust it is.
    static func product(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .museCode: "Muse Code"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }

    static func name(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .museCode: "Muse"
        case .cursor: "Cursor"
        case .antigravity: "Gemini"
        }
    }

    // The registry folder and id, fixed after setup.
    static func id(_ harness: AgentRegistration.Harness) -> String {
        switch harness {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .museCode: "muse"
        case .cursor: "cursor"
        case .antigravity: "gemini"
        }
    }

    // The effort a new registration starts with. Claude at low acks in about
    // 2.9 s at the median against 4.2 s at its default, with no more misreads
    // (front-desk test 2026.10.27). Codex starts at low too;
    // its latency is not measured yet. Muse
    // follows them; its latency is not measured either, nor Antigravity's.
    // Cursor has no effort of its own: it is part of the model's name.
    static func defaultEffort(_ harness: AgentRegistration.Harness) -> String? {
        switch harness {
        case .claudeCode, .codex, .museCode, .antigravity: "low"
        case .cursor: nil
        }
    }

    var name: String { Self.name(harness) }

    // The shell lookup can take a few seconds; it runs off the main thread.
    func detect() {
        let detector = detector
        let harness = harness
        Task.detached {
            let path = detector.find(harness)
            await MainActor.run { self.setExecutable(path) }
        }
    }

    // A debug path (OnboardingSnapshots): found at `path`, no lookup.
    func simulateFound(_ path: String) {
        setExecutable(path)
    }

    // A debug path: not installed, no lookup.
    func simulateMissing() {
        setExecutable(nil)
    }

    private func setExecutable(_ path: String?) {
        looking = false
        // An existing registration's own executable wins if it still runs.
        if let registered = current?.executable, FileManager.default.isExecutableFile(atPath: registered) {
            executable = registered
        } else {
            executable = path
        }
        if executable != nil {
            // A new agent is on; its registration waits for a folder.
            if current == nil { isOn = true }
        } else {
            isOn = false
        }
    }

    // What onboarding and Settings write for this harness, or nil when it
    // is off or incomplete. Keeps an existing registration's name, voice
    // and consolidation; the model, effort and fast mode are this choice's,
    // which start as the registration's, or a new one's default effort.
    var registration: AgentRegistration? {
        guard isOn, let executable, let root else { return nil }
        var registration = current ?? AgentRegistration(agent: Self.id(harness), name: Self.name(harness),
                                                        harness: harness, executable: executable, root: root)
        registration.executable = executable
        registration.root = root
        registration.model = model
        registration.effort = effort
        registration.fast = Self.written(fast: fast, harness: harness, current: current.map(\.fast))
        registration.enabled = Self.written(enabled: enabled, current: current.map(\.enabled))
        return registration
    }

    // What agent.json gets for fast mode: left out while it is the
    // harness's default and was left out before, and for Claude when off, as
    // a hand-written agent.json leaves it; otherwise written, so a new
    // Codex agent gets fast: true and turning Codex's off writes false.
    static func written(fast: Bool, harness: AgentRegistration.Harness, current: Bool??) -> Bool? {
        let isDefault = fast == AgentRegistration.defaultFast(harness)
        if isDefault, case .some(.none) = current { return nil }
        if !fast, !AgentRegistration.defaultFast(harness) { return nil }
        return fast
    }

    // What agent.json gets for `enabled`: false when off; left out when on,
    // unless it was written before.
    static func written(enabled: Bool, current: Bool??) -> Bool? {
        if !enabled { return false }
        if case .some(.some) = current { return true }
        return nil
    }

    // Whether it is registered and on: what the agents list says.
    var isRunning: Bool { isRegistered && current?.isEnabled == true }

    // Written to agent.json: what is registered is now `registration`.
    func saved(_ registration: AgentRegistration) {
        current = registration
    }

    // The folder panel as a sheet on `window`; a home folder or the disk's
    // root is refused with an alert. `chosen` runs once a folder is taken.
    func chooseFolder(in window: NSWindow, chosen: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose" // TODO(copy): copy
        panel.message = "The folder \(name) works in" // TODO(copy): copy
        if let root { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard self.detector.isAcceptableRoot(url.path) else {
                let alert = NSAlert()
                alert.messageText = "Choose a narrower folder" // TODO(copy): copy
                // TODO(copy): copy
                alert.informativeText = "An agent can't work in your home folder or the whole disk. Pick a project or workspace folder."
                alert.beginSheetModal(for: window)
                return
            }
            self.root = url.path
            self.isOn = true
            chosen()
        }
    }
}

// What the agents' panes say of an agent, shared by the onboarding's
// agents list and the Settings window.
extension AgentChoice {
    // Which CLI, and where; or that it is missing.
    var cliLine: String {
        let product = Self.product(harness)
        if looking { return "\(product) · looking…" } // TODO(copy): copy
        guard let executable else {
            return "\(product) · \(AgentDetector.command(for: harness)) was not found" // TODO(copy): copy
        }
        return "\(product) · \((executable as NSString).abbreviatingWithTildeInPath)"
    }

    // The workspace's folder name, its middle cut past 20 characters, so a
    // pill hugs its label; nil without one.
    var workspaceName: String? {
        guard let root else { return nil }
        let name = (root as NSString).lastPathComponent
        guard name.count > 20 else { return name }
        return "\(name.prefix(10))…\(name.suffix(9))"
    }

    // The Settings list's line: workspace, model and effort;
    // or why the agent has no workspace.
    var settingsSummary: String {
        if !looking, executable == nil { return "Not installed" } // TODO(copy): copy
        guard let root else { return "No workspace yet" } // TODO(copy): copy
        let model = model ?? "Default model" // TODO(copy): copy
        let effort = effort.map { "\(Self.effortLabel($0)) effort" } ?? "Default effort" // TODO(copy): copy
        return [(root as NSString).lastPathComponent, model, effort].joined(separator: " · ")
    }

    // The efforts each harness's CLI takes: Claude Code's --effort and
    // Codex's model_reasoning_effort, and Muse Code's reasoningEffort
    // without "none", which Meta's provider refuses. Antigravity's are
    // its thinking levels; Cursor's models carry their effort in their
    // own name ("gemini-4-carbon[reasoning_effort=high]"), so it has none here.
    static func efforts(_ harness: AgentRegistration.Harness) -> [String] {
        switch harness {
        case .claudeCode: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["minimal", "low", "medium", "high", "xhigh"]
        case .museCode: ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        case .cursor: []
        case .antigravity: ["low", "medium", "high", "xhigh", "max"]
        }
    }

    // The Effort menu: nil (the user's default), the harness's efforts, and
    // one written by hand that is neither, kept so it still shows.
    var effortOptions: [String?] {
        var options: [String?] = [nil] + Self.efforts(harness).map { $0 }
        if let effort, !Self.efforts(harness).contains(effort) { options.append(effort) }
        return options
    }

    // The main models of each harness, newest first, with the names their
    // makers give them. A convenience, not a limit: agent.json takes any
    // id, and one that is not here still shows in the menu. Checked
    // 2026.11.18: Claude's ids are Anthropic's current ones; Codex's are
    // the slugs in codex-cli 0.159.1's own list, and gpt-6.2-astra from a
    // working config. Muse's are not known, so it has none.
    static func models(_ harness: AgentRegistration.Harness) -> [(id: String, name: String)] {
        switch harness {
        case .claudeCode: [
            ("claude-fable-5-2", "Fable 5.2"),
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-sonnet-5-5", "Sonnet 5.5"),
            ("claude-haiku-5-5", "Haiku 5.5"),
        ]
        case .codex: [
            ("gpt-6.2-astra", "GPT-6.2 Astra"),
            ("gpt-6.1-sol", "GPT-6.1 Sol"),
            ("gpt-6-astra", "GPT-6 Astra"),
            ("gpt-6-sol", "GPT-6 Sol"),
            ("gpt-6-luna", "GPT-6 Luna"),
        ]
        case .museCode: []
        }
    }

    // The Model menu: nil (the user's default), the harness's main models,
    // and one written by hand that is not among them, kept so it shows.
    var modelOptions: [String?] {
        let known = Self.models(harness).map(\.id)
        var options: [String?] = [nil] + known.map { $0 }
        if let model, !known.contains(model) { options.append(model) }
        return options
    }

    // A model's name in the menu: its maker's name, or the id as written.
    func modelLabel(_ model: String?) -> String {
        guard let model else { return "Default" } // TODO(copy): copy
        return Self.models(harness).first { $0.id == model }?.name ?? model
    }

    static func effortLabel(_ effort: String?) -> String {
        guard let effort else { return "Default" } // TODO(copy): copy
        switch effort {
        case "xhigh": return "Extra high" // TODO(copy): copy
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

}

extension AgentRegistry {
    // Writes the agent's agent.json, then its harness's default mark unless
    // the folder has its own. A failure to copy the mark leaves the agent
    // registered, with the default still shown from the bundle; a failure
    // to write agent.json throws.
    @MainActor
    func register(_ registration: AgentRegistration) throws {
        try write(registration)
        do {
            try seedIcon(agent: registration.agent, harness: registration.harness, marks: AgentMarks.directory)
        } catch {
            SiriusLog.onboarding.error("\(registration.agent): couldn't copy its mark: \(error)")
        }
    }
}

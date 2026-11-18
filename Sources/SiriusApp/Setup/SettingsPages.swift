import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// The Settings window's page: the sidebar on the left, the section on the
// right, laid out as the approved mock (heap/0245/20261102-settings-agents-list.swift).
struct SettingsView: View {
    static let sidebarWidth: CGFloat = 200

    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.03))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                content
                    .id(model.focused.map { "agent-\($0.rawValue)" } ?? model.section.rawValue)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 56)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                // The onboarding's sky (NightSky), faint behind the panes so
                // the controls read as before; off under Reduce Transparency.
                if !reduceTransparency {
                    NightSky().opacity(Self.skyOpacity(colorScheme))
                }
            }
        }
        // Under the transparent title bar, as the mock: the insets above
        // count from the window's top edge.
        .ignoresSafeArea()
        // ⌘W closes: an accessory app has no menu bar of its own to carry
        // Close. Behind the page, so it takes no row.
        .background {
            Button("Close") { model.close() } // TODO(copy): copy
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onExitCommand { if !model.back() { model.close() } }
    }

    // The sky's strength: a quiet wash in dark mode, a bare tint in light.
    static func skyOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.45 : 0.06
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .keys: KeysPane(shortcuts: model.shortcuts, window: { [weak model] in model?.window })
        case .permissions: PermissionsPane(grants: model.grants)
        case .agents:
            if let harness = model.focused, let agent = model.agent(harness) {
                AgentDetail(agent: agent, model: model)
            } else {
                AgentsPane(model: model)
            }
        case .dictation: DictationPane(model: model)
        }
    }
}

// The sparkle, the name and the version, then a row per section, the
// selected one in Parrot's light-fill capsule.
private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 30, weight: .light))
                    .frame(height: 40)
                Text("Sirius").font(.headline)
                Text("Version \(model.version)") // TODO(copy): copy
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.bottom, 24)
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    SidebarRow(section: section, selected: section == model.section) {
                        model.select(section)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Hold to talk from its list, paste at the cursor as it follows from it,
// and Compose, recorded in place (ShortcutsModel).
private struct KeysPane: View {
    @ObservedObject var shortcuts: ShortcutsModel
    let window: () -> NSWindow?

    var body: some View {
        SettingsGroup("Keys") { // TODO(copy): copy
            PillRow("Hold to talk") { // TODO(copy): copy
                PillMenu(title: shortcuts.holdKey.menuTitle) {
                    ForEach(HoldKey.allCases, id: \.self) { key in
                        Button(key.menuTitle) { shortcuts.choose(key) }
                    }
                }
            }
            PillRow("Paste at cursor") { // TODO(copy): copy
                Text(shortcuts.holdKey.pasteGlyph)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            PillRow("Compose") { // TODO(copy): copy
                Button(shortcuts.composeText) {
                    shortcuts.isRecording ? shortcuts.cancelRecording() : shortcuts.startRecording(in: window())
                }
                .buttonStyle(.pill)
                .onDisappear { shortcuts.cancelRecording() }
            }
        }
    }
}

// Microphone and Accessibility, each Allowed or with its Allow pill, which
// prompts or opens the pane (Grants.allowSteps); live as they change.
private struct PermissionsPane: View {
    @ObservedObject var grants: GrantsModel

    var body: some View {
        SettingsGroup("Permissions") { // TODO(copy): copy
            PillRow("Microphone") { permission(.microphone) } // TODO(copy): copy
            PillRow("Accessibility") { permission(.accessibility) } // TODO(copy): copy
            if grants.parrotRunning {
                Text("Quit Parrot so fn isn't handled twice.") // TODO(copy): copy
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func permission(_ grant: Grant) -> some View {
        if grants.isGranted(grant) {
            Label("Allowed", systemImage: "checkmark.circle.fill") // TODO(copy): copy
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .padding(.vertical, 6)
        } else {
            Button("Allow") { grants.allow(grant) } // TODO(copy): copy
                .buttonStyle(.primaryPill)
                .disabled(grants.steps(grant).isEmpty)
        }
    }
}

// Every agent: its mark, name, workspace, model and effort, whether it is
// registered, and a chevron; a click puts it in focus.
private struct AgentsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup("Agents") { // TODO(copy): copy
            ForEach(model.agents) { agent in
                SettingsAgentRow(agent: agent) { model.focus(agent.harness) }
            }
        }
        ToastsGroup()
    }
}

// How long a toast stays before it leaves by itself (ToastStay). Alerts
// stay until dismissed whatever this says.
private struct ToastsGroup: View {
    @AppStorage(ToastStay.key) private var seconds = ToastStay.defaultSeconds

    var body: some View {
        SettingsGroup("Toasts") { // TODO(copy): copy
            PillRow("Stay for") { // TODO(copy): copy
                PillMenu(title: label(ToastStay.choices.contains(seconds) ? seconds : ToastStay.defaultSeconds)) {
                    ForEach(ToastStay.choices, id: \.self) { choice in
                        Button(label(choice)) { seconds = choice }
                    }
                }
            }
        }
    }

    private func label(_ value: TimeInterval) -> String { "\(Int(value)) s" }
}

private struct SettingsAgentRow: View {
    @ObservedObject var agent: AgentChoice
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                AgentMark(harness: agent.harness, size: 22, ink: .primary)
                    .opacity(agent.isRegistered && !agent.isRunning ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                    Text(agent.settingsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(agent.isRunning ? "On" : "Off") // TODO(copy): copy
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// One agent in focus under a bare "‹": its mark and name, its
// CLI, then whether it runs (once registered), Workspace, Fast mode near
// the top, Model and Effort.
// Each change writes its agent.json (SettingsModel.save); until it has a
// workspace, a new agent's changes wait for one.
private struct AgentDetail: View {
    @ObservedObject var agent: AgentChoice
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Agents") // TODO(copy): copy
            .accessibilityLabel("Back to Agents") // TODO(copy): copy
            .padding(.top, -28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    AgentMark(harness: agent.harness, size: 18, ink: .primary)
                    Text(agent.name).font(.title3.weight(.semibold))
                }
                Text(agent.cliLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if agent.isRegistered {
                PillRow("Enabled", note: agent.enabled ? nil : "Not started and not in the composer's rotation") { // TODO(copy): copy
                    PillSwitch(label: "Enabled", isOn: Binding( // TODO(copy): copy
                        get: { agent.enabled },
                        set: { agent.enabled = $0; model.save(agent) }
                    ))
                }
            }
            PillRow("Workspace", note: workspaceNote) { // TODO(copy): copy
                Button {
                    if let window = model.window { agent.chooseFolder(in: window) { model.save(agent) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(agent.workspaceName ?? "Choose…") // TODO(copy): copy
                    }
                }
                .buttonStyle(.pill)
            }
            .disabled(agent.executable == nil)
            Group {
                PillRow("Fast mode") { // TODO(copy): copy
                    PillSwitch(label: "Fast mode", isOn: Binding( // TODO(copy): copy
                        get: { agent.fast },
                        set: { agent.fast = $0; model.save(agent) }
                    ))
                }
                PillRow("Model") { // TODO(copy): copy
                    PillMenu(title: AgentChoice.modelLabel(agent.model)) {
                        ForEach(agent.modelOptions, id: \.self) { option in
                            Button(AgentChoice.modelLabel(option)) { agent.model = option; model.save(agent) }
                        }
                    }
                }
                PillRow("Effort") { // TODO(copy): copy
                    PillMenu(title: AgentChoice.effortLabel(agent.effort)) {
                        ForEach(agent.effortOptions, id: \.self) { option in
                            Button(AgentChoice.effortLabel(option)) { agent.effort = option; model.save(agent) }
                        }
                    }
                }
            }
            .disabled(agent.executable == nil)
        }
    }

    // The workspace's path; or, for an agent not yet registered, that one
    // starts it.
    private var workspaceNote: String? {
        if let root = agent.root, agent.isRegistered { return (root as NSString).abbreviatingWithTildeInPath }
        guard agent.executable != nil else { return nil }
        return "Choose one to start \(agent.name)" // TODO(copy): copy
    }
}

// The speech model dictation uses, shown with its size; DictationModel reads
// it at launch, so it is not changed here.
private struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsGroup("Dictation") { // TODO(copy): copy
            PillRow("Model", note: model.dictationNote) { // TODO(copy): copy
                Text(model.dictation.displayName)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
        }
    }
}

import AppKit
import ParrotCore
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// A debug path for reviewing the Settings window against its mock without
// launching Sirius, touching the registry or asking for any grant, as
// OnboardingSnapshots: `Sirius --settings-snapshots <dir>` renders each pane
// at 2x in dark mode to <dir>/<name>.png and exits before the socket server
// starts. The grants are simulated; the agents and their folders are made
// up; nothing is written.
@MainActor
enum SettingsSnapshots {
    static let flag = "--settings-snapshots"

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for shot in shots {
            let model = SettingsModel.preview()
            shot.prepare(model)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000),
                                                      size: SettingsWindow.size),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.orderFrontRegardless()
            // The frame view, so the close button shows as in the window.
            let content = hosting.superview ?? hosting
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            window.orderOut(nil)
            let url = directory.appendingPathComponent("\(shot.name).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        exit(0)
    }

    private struct Shot {
        let name: String
        var prepare: @MainActor (SettingsModel) -> Void = { _ in }
    }

    private static var shots: [Shot] {
        [
            Shot(name: "1-keys"),
            Shot(name: "2-permissions") {
                $0.grants.simulate(GrantState(accessibility: false, microphone: .granted))
                $0.select(.permissions)
            },
            Shot(name: "3-agents") { $0.select(.agents) },
            Shot(name: "4-agent-claude") { $0.focus(.claudeCode) },
            Shot(name: "5-agent-codex") { $0.focus(.codex) },
            Shot(name: "6-dictation") { $0.select(.dictation) },
        ]
    }
}

extension SettingsModel {
    // A model for the snapshots: Claude registered in a made-up folder, fast
    // mode off; Codex registered with fast left out, so on by its default
    //; both found.
    static func preview() -> SettingsModel {
        let registrations = [
            AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                              executable: "/Users/you/.local/bin/claude", root: "/Users/you/Projects/humanitas",
                              effort: "low"),
            AgentRegistration(agent: "codex", name: "Codex", harness: .codex,
                              executable: "/opt/homebrew/bin/codex", root: "/Users/you/Projects/sirius",
                              effort: "low"),
        ]
        let agents = AgentChoice.choices(existing: registrations, detector: AgentDetector())
        for agent in agents {
            agent.simulateFound(agent.current?.executable ?? "/usr/local/bin/\(AgentDetector.command(for: agent.harness))")
        }
        let dictation = ModelRegistry.find(DictationModel.defaultID) ?? ModelRegistry.shared[0]
        return SettingsModel(agents: agents, shortcuts: ShortcutsModel(compose: .compose, holdKey: .fn),
                             dictation: dictation, write: { _ in })
    }
}

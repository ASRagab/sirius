import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol
import SwiftUI

// A debug path for reviewing the onboarding against its design frames
// without opening a window, touching the running Sirius or asking for any
// grant: `Sirius --onboarding-snapshots <dir>` renders each state of the
// sheet at 2x to <dir>/<n>-<name>.png and exits before the socket server
// starts. The grants are simulated (GrantsModel.simulate), never read from
// or asked of the system; the agents and their folders are made up, never
// read from the user's files.
@MainActor
enum OnboardingSnapshots {
    static let flag = "--onboarding-snapshots"

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for shot in shots {
            let model = OnboardingModel.preview(trusted: shot.trusted)
            shot.prepare(model)
            let content = OnboardingWindow.surface(around: OnboardingView(model: model))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000),
                                                      size: OnboardingWindow.size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = content
            window.backgroundColor = .clear
            window.isOpaque = false
            window.orderFrontRegardless()
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            window.orderOut(nil)
            guard let image = bitmap.cgImage else {
                FileManager.default.createFile(atPath: directory.path + "/FAILED-\(shot.name)", contents: nil)
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            let url = directory.appendingPathComponent("\(shot.name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        exit(0)
    }

    private struct Shot {
        let name: String
        // Whether the agents were offered trusted folders.
        var trusted = true
        var prepare: @MainActor (OnboardingModel) -> Void = { _ in }
    }

    private static let none = GrantState(accessibility: false, microphone: .notDetermined)
    private static let all = GrantState(accessibility: true, microphone: .granted)

    private static var shots: [Shot] {
        [
            Shot(name: "1-sheet") { $0.grants.simulate(none) },
            Shot(name: "2-sheet-microphone") {
                $0.grants.simulate(GrantState(accessibility: false, microphone: .granted))
            },
            Shot(name: "3-sheet-granted") { $0.grants.simulate(all) },
            Shot(name: "4-agents") { model in
                model.grants.simulate(all)
                model.pane = .agents
            },
            Shot(name: "4b-agent-focused") { model in
                model.grants.simulate(all)
                model.pane = .agent(.claudeCode)
            },
            Shot(name: "5-sheet-no-trusted-folders", trusted: false) { $0.grants.simulate(none) },
            Shot(name: "5b-agents-no-trusted-folders", trusted: false) { model in
                model.grants.simulate(none)
                model.pane = .agents
            },
            Shot(name: "6-sheet-recording") { model in
                model.grants.simulate(all)
                model.shortcuts.simulate(.recording(hint: nil))
            },
        ]
    }
}

extension OnboardingModel {
    // A model for the snapshots: both harnesses found, each with a made-up
    // trusted folder when `trusted`, none otherwise.
    static func preview(trusted: Bool) -> OnboardingModel {
        let agents = AgentRegistration.Harness.allCases.map { harness in
            AgentChoice(harness: harness, current: nil, detector: AgentDetector(),
                        trusted: trusted ? "/Users/you/Projects/\(AgentChoice.id(harness))-work" : nil)
        }
        for agent in agents { agent.simulateFound("/usr/local/bin/\(AgentDetector.command(for: agent.harness))") }
        return OnboardingModel(agents: agents, shortcuts: ShortcutsModel(compose: .compose, holdKey: .fn))
    }
}

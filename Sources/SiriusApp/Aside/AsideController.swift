import AppKit
import SiriusAdapters
import SiriusCore
import SiriusProtocol

// The asides on screen. An aside
// opens two ways: the user sends from the composer with ⌘Return, and what
// they typed is its first turn; or the agent answers a message with
// `display aside`, and its brief stands in for a first turn (the fork
// already holds the user's message). Either way the window is up at once
// and the agent's fork starts behind it (AgentHost.openAside).
//
// Closing the window ends the aside: its harness stops, what was said is
// filed, and the agent's main session is left a note of where.
@MainActor
final class AsideController {
    // More than a few is a mistake, the agent's or a held key's.
    static let limit = 6

    private struct Open {
        var window: AsideWindow
        var reading: Task<Void, Never>
    }

    private let host: AgentHost
    private let ambient = AmbientContextSource()
    private var open: [String: Open] = [:]

    private let anchors: AmbientAnchors?

    init(host: AgentHost, anchors: AmbientAnchors? = nil) {
        self.host = host
        self.anchors = anchors
    }

    enum Opening {
        // The user's own words, with any files, and what the app in front
        // had open and selected when they wrote them.
        case user(text: String, attachments: [URL], context: AmbientSnapshot? = nil)
        // The agent's brief, and the handle of the item to open beside, if
        // it named one.
        case agent(brief: String, anchor: String? = nil)
    }

    enum Failure: Error { case tooMany, unknownAgent }

    // Opens the window and starts the first turn. Throws when the agent is
    // not hosted or too many asides are open.
    func openAside(agent: String, _ opening: Opening) async throws {
        guard open.count < Self.limit else { throw Failure.tooMany }
        let topic: String
        switch opening {
        case .user(let text, let attachments, _):
            topic = text.isEmpty ? attachments.map(\.lastPathComponent).joined(separator: ", ") : text
        case .agent(let brief, _):
            topic = brief
        }
        let session: AsideSession
        do {
            session = try await host.openAside(agent: agent, topic: topic)
        } catch {
            SiriusLog.asides.error("aside for \(agent) did not open: \(error)")
            throw Failure.unknownAgent
        }
        let name = await host.agents().first { $0.agent == agent }?.name ?? agent
        let window = AsideWindow(agent: agent, name: name, mark: AgentMarks.mark(agent: agent))
        let id = session.id
        window.onSend = { [weak self] text, attachments in self?.send(id, text: text, attachments: attachments) }
        window.onClose = { [weak self] in self?.closed(id) }
        let reading = Task { [weak window] in
            for await event in session.events {
                guard let window else { return }
                switch event {
                case .event(let event):
                    window.hear(event)
                case .turnEnded(let failure):
                    if let failure { SiriusLog.asides.error("aside \(id): turn failed: \(failure)") }
                    window.end(failure: failure)
                }
            }
        }
        open[id] = Open(window: window, reading: reading)

        switch opening {
        case .user(let text, let attachments, let context):
            window.ask(text, attachments: attachments)
            send(id, text: text, attachments: attachments, context: context?.messageContext)
        case .agent(let brief, _):
            window.await_()
            send(id, text: AsidePrompts.opened(brief: brief))
        }
        place(window.window)
        switch opening {
        case .user(_, _, let context?):
            if let item = context.anchor { await place(window.window, beside: item) }
        case .agent(_, let handle?):
            // A handle Sirius never gave, or gave too long ago, is not an
            // error: the aside opens where any other would.
            if let item = anchors?.resolve(handle) {
                await place(window.window, beside: item)
            } else {
                SiriusLog.asides.info("aside: anchor not known; placed as usual")
            }
        default:
            break
        }
        // An accessory app is never active on its own (SettingsWindow).
        NSApp.activate()
        window.window.makeKeyAndOrderFront(nil)
        window.window.orderFrontRegardless()
        window.focus()
        SiriusLog.asides.info("aside \(id) opened for \(agent)")
    }

    private func send(_ id: String, text: String, attachments: [URL] = [], context: Message.Context? = nil) {
        let host = host
        Task { [weak self] in
            do {
                try await host.sendAside(id, text: text, attachments: attachments, context: context)
            } catch {
                SiriusLog.asides.error("aside \(id): send failed: \(error)")
                self?.open[id]?.window.end(failure: "\(error)")
            }
        }
    }

    private func closed(_ id: String) {
        guard let aside = open.removeValue(forKey: id) else { return }
        aside.reading.cancel()
        SiriusLog.asides.info("aside \(id) closed")
        let host = host
        Task.detached { await host.closeAside(id) }
    }

    // Beside what the user had selected, when the app it is in can say
    // where that is: one question, to the provider and run that issued the
    // item, with the usual limit. No answer, an item out of view or no room
    // beside it leaves the window where `place` put it.
    private func place(_ window: NSWindow, beside anchor: AmbientItemRef) async {
        guard let location = await ambient.locate(anchor) else {
            return SiriusLog.asides.info("aside: \(anchor.id) could not be located; placed as usual")
        }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        guard let frame = AmbientPlacement.frame(
            beside: location, size: window.frame.size, screens: NSScreen.screens.map(\.visibleFrame),
            primaryHeight: primary
        ) else {
            return SiriusLog.asides.info("aside: \(anchor.id) is \(location.state); placed as usual")
        }
        window.setFrame(frame, display: false)
        SiriusLog.asides.info("aside placed beside \(anchor.id)")
    }

    // On the screen in use, toward its right edge, beside the work; each
    // further aside a step down and left of the last.
    private func place(_ window: NSWindow) {
        guard let screen = NSScreen.active ?? NSScreen.main else { return window.center() }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(AsideWindow.size.width, visible.width - 80),
                          height: min(AsideWindow.size.height, visible.height - 80))
        let step = CGFloat(open.count - 1) * 26
        let origin = NSPoint(x: max(visible.minX + 20, visible.maxX - size.width - 48 - step),
                             y: max(visible.minY + 20, visible.midY - size.height / 2 - step))
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

import AppKit
import SiriusCore

// A debug path for reviewing the aside's page without an agent:
// `Sirius --aside-snapshots <dir>` renders the window off every screen at
// 2x to <dir>/<name>.png and exits before the socket server starts, as
// ComposerSnapshots does.
@MainActor
enum AsideSnapshots {
    static let flag = "--aside-snapshots"

    static let answer = """
        Short version: **the queue is per agent**, so a slow turn in one never holds up another.

        ## How a message moves

        1. The composer hands the text to `AgentHost.send`.
        2. The host copies attachments, logs the message and queues it.
           The queue runs one turn at a time.
        3. The adapter delivers it as a turn; the agent replies through `sirius display`.

        A few things follow from that:

        - Messages arrive in the order sent.
          - Typing while a turn runs *steers* it where the harness can.
        - A failed turn is reported, and the next one still runs.

        ```swift
        try await hosted.queue.send(Message(id: id, agent: agent, text: text))
        ```

        > An aside is the exception: its own fork, its own queue.

        | Harness | Fork |
        |---------|------|
        | Claude  | `--fork-session` |

        See [the plan](https://example.com) for the rest.
        """

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shots: [(name: String, play: (AsideWindow) -> Void)] = [
            ("1-waiting", { $0.ask("How does a message get from the composer to the agent?") }),
            ("2-streaming", {
                $0.ask("How does a message get from the composer to the agent?")
                $0.hear(String(answer.prefix(420)))
            }),
            ("3-answered", {
                $0.ask("How does a message get from the composer to the agent?")
                $0.hear(answer)
                $0.end(failure: nil)
            }),
            ("4-follow-up", {
                $0.ask("How does a message get from the composer to the agent?")
                $0.hear("One turn at a time, per agent.")
                $0.end(failure: nil)
                $0.ask("And when a turn fails?\nDoes the next one wait?")
                $0.hear("No. The failure is reported and the next turn runs.")
                $0.end(failure: "the harness stopped")
            }),
            ("6-working", {
                $0.ask("Which files does the queue touch?")
                $0.hear(.textStarted(id: "a", phase: .commentary))
                $0.hear(.textDelta(id: "a", text: "I'll search the sources for the queue's writes."))
                $0.hear(.textEnded(id: "a", phase: .commentary))
                $0.hear(.toolCall(ToolCall(id: "t", name: "Grep", title: "AgentTurnQueue", kind: .search, status: .inProgress)))
            }),
            ("7-after-a-tool", {
                $0.ask("Which files does the queue touch?")
                $0.hear(.textStarted(id: "a", phase: .commentary))
                $0.hear(.textDelta(id: "a", text: "I'll search the sources for the queue's writes."))
                $0.hear(.textEnded(id: "a", phase: .commentary))
                $0.hear(.toolCall(ToolCall(id: "t", name: "Grep", title: "AgentTurnQueue", kind: .search, status: .inProgress)))
                $0.hear(.toolCallUpdated(id: "t", ToolCallChange(status: .completed)))
                $0.hear(.textStarted(id: "b", phase: .answer))
                $0.hear(.textDelta(id: "b", text: "Two: `state.json`, which holds the turns waiting, and the agent's log."))
            }),
            ("5-image", {
                let url = directory.appendingPathComponent("sample.png")
                let sample = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
                    NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 30)
                    return true
                }
                try? sample.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:])?.write(to: url)
                $0.ask("What is wrong in this screenshot?", attachments: [url])
                $0.hear("The header overlaps the first row.")
                $0.attach([url])
            }),
        ]
        for shot in shots {
            let aside = AsideWindow(agent: "claude", name: "Claude", mark: AgentMarks.mark(agent: "claude"))
            // A titled window is pulled back onto a screen unless told not to be.
            (aside.window as? AsidePanel)?.staysWherePut = true
            aside.isPaced = false
            aside.window.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: AsideWindow.size), display: false)
            aside.window.orderFrontRegardless()
            shot.play(aside)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            aside.window.contentView?.layoutSubtreeIfNeeded()
            let url = directory.appendingPathComponent("\(shot.name).png")
            // Through the views' own drawing, over the window's background.
            if let content = aside.window.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                let image = NSImage(size: content.bounds.size)
                image.lockFocus()
                Palette.background.setFill()
                content.bounds.fill()
                rep.draw(in: content.bounds)
                image.unlockFocus()
                let data = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:])
                try? data?.write(to: url)
                print(url.path)
            } else {
                FileManager.default.createFile(atPath: directory.path + "/FAILED-\(shot.name)", contents: nil)
            }
            aside.window.orderOut(nil)
        }
        exit(0)
    }
}

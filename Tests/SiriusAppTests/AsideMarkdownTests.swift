import AppKit
import SiriusCore
import XCTest
@testable import SiriusApp

@MainActor
final class AsideMarkdownTests: XCTestCase {
    typealias Block = AsideMarkdown.Block

    func testBlocks() {
        let text = """
        # Title

        First line
        second line.

        - one
          continued
        - two
          1. nested
        > quoted
        > more

        ---

        ```swift
        let x = 1

        # not a heading
        ```
        | a | b |
        |---|---|
        """
        XCTAssertEqual(AsideMarkdown.blocks(text), [
            .heading(level: 1, text: "Title"),
            .paragraph("First line second line."),
            .item(level: 0, marker: "•", text: "one continued"),
            .item(level: 0, marker: "•", text: "two"),
            .item(level: 1, marker: "1.", text: "nested"),
            .quote("quoted more"),
            .rule,
            .code("let x = 1\n\n# not a heading"),
            .table("| a | b |\n|---|---|"),
        ])
    }

    // A streaming answer is rendered before it is whole.
    func testAnUnclosedFenceIsCodeToTheEnd() {
        XCTAssertEqual(AsideMarkdown.blocks("Look:\n```\nlet x"), [.paragraph("Look:"), .code("let x")])
    }

    func testNotEveryNumberOrHashStartsABlock() {
        XCTAssertEqual(AsideMarkdown.blocks("#hashtag\n2026. A year"), [.paragraph("#hashtag 2026. A year")])
        XCTAssertEqual(AsideMarkdown.blocks("**bold** start"), [.paragraph("**bold** start")])
    }

    func testInlineStyles() {
        let style = AsideMarkdown.Style.standard
        let text = AsideMarkdown.inline("a **b** `c` [d](https://example.com) *e", font: style.body,
                                        color: style.color, style: style)
        XCTAssertEqual(text.string, "a b c d *e")
        func font(at offset: Int) -> NSFont? { text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont }
        XCTAssertTrue(font(at: 2)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(font(at: 4)?.isFixedPitch ?? false)
        XCTAssertNotNil(text.attribute(.link, at: 6, effectiveRange: nil))
        XCTAssertFalse(font(at: 0)?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
    }

    func testRenderKeepsEveryBlocksText() {
        let text = AsideMarkdown.render("# T\n\npara\n\n- a\n- b\n\n```\ncode\nmore\n```").string
        XCTAssertEqual(text, "T\npara\n•\ta\n•\tb\ncode\u{2028}more")
    }

    func testTheTranscriptSettlesAnAnswerWhenItsTurnEnds() {
        var transcript = AsideTranscript()
        transcript.append(.user("why?"))
        transcript.begin()
        XCTAssertTrue(transcript.tail.string.contains("Thinking"))
        transcript.hear("Be")
        transcript.hear("cause.")
        XCTAssertTrue(transcript.tail.string.hasSuffix("Because."))
        XCTAssertFalse(transcript.head.string.contains("Because."))
        transcript.queue("and then?")
        XCTAssertTrue(transcript.tail.string.hasSuffix("and then?"))
        transcript.end(failure: nil)
        XCTAssertEqual(transcript.entries, [.user("why?"), .agent("Because.")])
        XCTAssertTrue(transcript.head.string.hasSuffix("Because."))
        XCTAssertEqual(transcript.tail.length, 0)
        XCTAssertEqual(transcript.dequeue(), AsideTranscript.Queued(text: "and then?"))
        XCTAssertNil(transcript.dequeue())
    }

    // Two runs with a tool call between them: each is its own entry, the
    // first kept as rendered once the second begins.
    func testARunThatEndedIsKeptWhenTheNextBegins() {
        var transcript = AsideTranscript()
        transcript.append(.user("list"))
        transcript.begin()
        transcript.hear(.textStarted(id: "a", phase: nil))
        transcript.hear(.textDelta(id: "a", text: "Looking."))
        transcript.hear(.textEnded(id: "a", phase: nil))
        // Ended, but still the last text: it stays in the tail.
        XCTAssertFalse(transcript.head.string.contains("Looking."))
        XCTAssertTrue(transcript.tail.string.contains("Looking."))
        transcript.hear(.toolCall(ToolCall(id: "t", name: "Bash", title: "ls -la", kind: .execute, status: .inProgress)))
        XCTAssertEqual(transcript.activity, "Running ls -la…")
        XCTAssertTrue(transcript.tail.string.hasSuffix("Running ls -la…"))
        transcript.hear(.toolCallUpdated(id: "t", ToolCallChange(status: .completed)))
        XCTAssertEqual(transcript.activity, "Thinking…", "waiting on the model again")
        transcript.hear(.textStarted(id: "b", phase: nil))
        XCTAssertTrue(transcript.head.string.hasSuffix("Looking."), "kept once the next run began")
        XCTAssertEqual(transcript.entries, [.user("list"), .agent("Looking.")])
        transcript.hear(.textDelta(id: "b", text: "Two files."))
        XCTAssertNil(transcript.activity, "writing")
        XCTAssertFalse(transcript.tail.string.contains("Looking."))
        XCTAssertTrue(transcript.tail.string.hasSuffix("Two files."))
        XCTAssertEqual(transcript.streaming, "Two files.")
        transcript.end(failure: nil)
        XCTAssertEqual(transcript.entries, [.user("list"), .agent("Looking."), .agent("Two files.")])
        XCTAssertEqual(transcript.tail.length, 0)
        XCTAssertNil(transcript.activity)
    }

    // A turn cut off: its run never ended, its tool call never finished.
    func testAnInterruptedTurnKeepsWhatWasSaid() {
        var transcript = AsideTranscript()
        transcript.begin()
        transcript.hear(.textStarted(id: "a", phase: nil))
        transcript.hear(.textDelta(id: "a", text: "Lighthouses began"))
        transcript.hear(.toolCall(ToolCall(id: "t", title: "sleep 9", kind: .execute, status: .inProgress)))
        transcript.end(failure: "interrupted")
        XCTAssertEqual(transcript.entries, [.agent("Lighthouses began"), .failure("interrupted")])
        XCTAssertFalse(transcript.isRunning)
        // Nothing of it is left for the next turn.
        transcript.begin()
        XCTAssertEqual(transcript.activity, "Thinking…")
        XCTAssertTrue(transcript.tail.string.hasSuffix("Thinking…"))
    }

    // Commentary is dimmed, whether the harness says so when the run
    // starts (Codex) or only when it ends (Muse).
    func testCommentaryIsDimmedAndTheAnswerIsNot() throws {
        func color(_ text: NSAttributedString, of word: String) throws -> NSColor {
            let range = (text.string as NSString).range(of: word)
            XCTAssertNotEqual(range.location, NSNotFound, word)
            return try XCTUnwrap(text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
        }
        var transcript = AsideTranscript()
        let style = transcript.style
        transcript.begin()
        transcript.hear(.textStarted(id: "a", phase: .commentary))
        transcript.hear(.textDelta(id: "a", text: "Checking the queue."))
        XCTAssertEqual(try color(transcript.tail, of: "Checking"), style.secondary, "said at the start")
        transcript.hear(.textEnded(id: "a", phase: .commentary))
        transcript.hear(.textStarted(id: "b", phase: nil))
        transcript.hear(.textDelta(id: "b", text: "Reading on."))
        XCTAssertEqual(try color(transcript.tail, of: "Reading"), style.color, "not known yet")
        transcript.hear(.textEnded(id: "b", phase: .commentary))
        XCTAssertEqual(try color(transcript.tail, of: "Reading"), style.secondary, "said at the end")
        transcript.hear(.textStarted(id: "c", phase: .answer))
        transcript.hear(.textDelta(id: "c", text: "It is durable."))
        transcript.end(failure: nil)
        XCTAssertEqual(transcript.entries, [.commentary("Checking the queue."), .commentary("Reading on."),
                                            .agent("It is durable.")])
        XCTAssertEqual(try color(transcript.head, of: "Checking"), style.secondary)
        XCTAssertEqual(try color(transcript.head, of: "durable"), style.color)
    }

    func testTheActivityLineSaysWhatTheAgentIsDoing() {
        var transcript = AsideTranscript()
        XCTAssertNil(transcript.activity, "no turn runs")
        transcript.begin()
        XCTAssertEqual(transcript.activity, "Thinking…")
        transcript.hear(.reasoningStarted(id: "r"))
        XCTAssertEqual(transcript.activity, "Thinking…")
        transcript.hear(.reasoningEnded(id: "r"))
        // Claude announces a call before its input, and so its title, is in.
        transcript.hear(.toolCall(ToolCall(id: "1", name: "Read", kind: .read, status: .pending)))
        XCTAssertEqual(transcript.activity, "Reading Read…")
        transcript.hear(.toolCallUpdated(id: "1", ToolCallChange(inputDelta: "{")))
        transcript.hear(.toolCallUpdated(id: "1", ToolCallChange(status: .inProgress, title: "a.txt")))
        XCTAssertEqual(transcript.activity, "Reading a.txt…")
        // Two at once: the later one shows, then the one still running.
        transcript.hear(.toolCall(ToolCall(id: "2", name: "Agent", title: "Explore the parser", status: .inProgress)))
        XCTAssertEqual(transcript.activity, "Explore the parser…")
        transcript.hear(.toolCallUpdated(id: "2", ToolCallChange(status: .failed)))
        XCTAssertEqual(transcript.activity, "Reading a.txt…")
        transcript.hear(.notice(Notice(severity: .warning, text: "Retrying (2 of 10): overloaded", retrying: true)))
        XCTAssertEqual(transcript.activity, "Retrying (2 of 10): overloaded")
        transcript.hear(.toolCallUpdated(id: "1", ToolCallChange(status: .completed)))
        transcript.hear(.textDelta(id: "a", text: "Done."))
        XCTAssertNil(transcript.activity, "the notice goes when the agent goes on")
        // The turn has ended and only its text is still coming in.
        transcript.hear(.textEnded(id: "a", phase: nil))
        XCTAssertEqual(transcript.activity, "Thinking…")
        transcript.isFinishing = true
        XCTAssertNil(transcript.activity)
    }

    func testAUsersFilesAreShownWithTheirWords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picture = directory.appendingPathComponent("shot.png")
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:]))
        try png.write(to: picture)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: notes)

        var transcript = AsideTranscript()
        transcript.append(.user("look", [picture, notes]))
        let head = transcript.head
        // The image as an attachment, the other file by name under the words.
        XCTAssertTrue(head.string.hasPrefix("\u{FFFC}"))
        XCTAssertTrue(head.string.hasSuffix("look\u{2028}notes.txt"))
        XCTAssertNotNil(head.attribute(.attachment, at: 0, effectiveRange: nil))

        // An image alone is a message too.
        var only = AsideTranscript()
        only.append(.user("", [picture]))
        XCTAssertEqual(only.head.string, "\u{FFFC}")
    }

    // A burst from the harness reaches the page over time, and the turn
    // settles, sending what waited, only once it is all there.
    func testTheWindowPacesABurstAndSettlesAfterIt() {
        let aside = AsideWindow(agent: "claude", name: "Claude", mark: nil)
        var sent: [String] = []
        aside.onSend = { text, _ in sent.append(text) }
        aside.ask("why?")
        let answer = String(repeating: "word ", count: 120)
        aside.hear(answer)
        aside.end(failure: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let early = aside.pageText
        XCTAssertTrue(early.contains("word"), "some of it shows at once")
        XCTAssertFalse(early.contains(answer.trimmingCharacters(in: .whitespaces)), "not all of it")
        XCTAssertTrue(aside.isAwaiting)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertTrue(aside.pageText.contains(answer.trimmingCharacters(in: .whitespaces)))
        XCTAssertFalse(aside.isAwaiting)
        XCTAssertEqual(sent, [])
    }

    // What the agent does between runs waits its turn behind the text
    // still coming in: the page never says "Running" above words not shown.
    func testTheWindowShowsEventsInOrderBehindThePacedText() {
        let aside = AsideWindow(agent: "claude", name: "Claude", mark: nil)
        aside.ask("list")
        let remark = String(repeating: "look ", count: 60)
        aside.hear(.textStarted(id: "a", phase: nil))
        aside.hear(.textDelta(id: "a", text: remark))
        aside.hear(.textEnded(id: "a", phase: nil))
        aside.hear(.toolCall(ToolCall(id: "t", name: "Bash", title: "ls -la", kind: .execute, status: .inProgress)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(aside.pageText.contains("Running ls -la"), "the remark is not all there yet")
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        XCTAssertTrue(aside.pageText.hasSuffix("Running ls -la…"))
        aside.hear(.toolCallUpdated(id: "t", ToolCallChange(status: .completed)))
        aside.hear(.textStarted(id: "b", phase: nil))
        aside.hear(.textDelta(id: "b", text: "Two files."))
        aside.hear(.textEnded(id: "b", phase: nil))
        aside.end(failure: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertFalse(aside.isAwaiting)
        XCTAssertFalse(aside.pageText.contains("Running"))
        XCTAssertFalse(aside.pageText.contains("Thinking"))
        XCTAssertTrue(aside.pageText.hasSuffix("Two files."))
        XCTAssertTrue(aside.pageText.contains(remark.trimmingCharacters(in: .whitespaces)))
    }

    func testTheNewestTextIsSoftAtItsEdge() {
        var transcript = AsideTranscript()
        transcript.begin()
        transcript.hear(String(repeating: "a", count: 60))
        func alpha(_ text: NSAttributedString, _ index: Int) -> CGFloat {
            (text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.alphaComponent ?? -1
        }
        let soft = transcript.tail(fade: .init(width: 20, settled: 0))
        XCTAssertEqual(alpha(soft, 0), 1, accuracy: 0.001)
        XCTAssertEqual(alpha(soft, 59), AsideTranscript.Fade.floor, accuracy: 0.001)
        XCTAssertGreaterThan(alpha(soft, 50), alpha(soft, 59))
        // Firmed up all the way, and with no fade asked for, it is plain.
        XCTAssertEqual(alpha(transcript.tail(fade: .init(width: 20, settled: 20)), 59), 1, accuracy: 0.001)
        XCTAssertEqual(alpha(transcript.tail, 59), 1, accuracy: 0.001)
    }

    func testAFailedTurnIsSaidAndAnEmptyAnswerLeavesNoEntry() {
        var transcript = AsideTranscript()
        transcript.begin()
        transcript.end(failure: "stopped")
        XCTAssertEqual(transcript.entries, [.failure("stopped")])
    }
}

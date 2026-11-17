import AppKit
import XCTest
@testable import SiriusApp

// A typed -> becomes →, and ⌘Z gives the literal -> back. Each keystroke
// runs the run loop once, as separate key events would.
@MainActor
final class ComposerArrowTests: XCTestCase {
    private var window: NSWindow!
    private var view: ComposerTextView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isRichText = false
        view.allowsUndo = true
        window.contentView = view
        window.makeFirstResponder(view)
    }

    private func type(_ text: String) {
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // ⌘⌫ with the caret at the start takes the context off first, then
    // the last file; with text before the caret it deletes text as usual,
    // and ⌫ alone never touches the context.
    func testCommandDeleteAtTheStartRemovesTheContextThenAFile() {
        var context = 1, files = 1
        view.onRemoveContext = { context > 0 ? { context -= 1; return true }() : false }
        view.onRemoveLastAttachment = { files > 0 ? { files -= 1; return true }() : false }

        type("hi")
        view.deleteToBeginningOfLine(nil)
        XCTAssertEqual(view.string, "")
        XCTAssertEqual([context, files], [1, 1])

        view.deleteToBeginningOfLine(nil)
        XCTAssertEqual([context, files], [0, 1])
        view.deleteToBeginningOfLine(nil)
        XCTAssertEqual([context, files], [0, 0])
    }

    func testDeleteAloneLeavesTheContext() {
        var context = 1
        view.onRemoveContext = { context -= 1; return true }
        view.deleteBackward(nil)
        XCTAssertEqual(context, 1)
    }

    func testArrowReplacesHyphenGreaterThan() {
        type("lib -> cook")
        XCTAssertEqual(view.string, "lib → cook")
    }

    func testUndoRestoresLiteral() throws {
        type("lib ->")
        XCTAssertEqual(view.string, "lib →")
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, "lib ->")
    }

    // The > opens a fresh typing run (as after a paste or an undo), so it
    // and the arrow share one key event's undo group.
    func testUndoRestoresLiteralWhenGreaterThanStartsATypingRun() throws {
        type("lib -")
        view.breakUndoCoalescing()
        type(">")
        XCTAssertEqual(view.string, "lib →")
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, "lib ->")
    }

    func testGreaterThanAloneIsUntouched() {
        type("a > b")
        XCTAssertEqual(view.string, "a > b")
    }
}

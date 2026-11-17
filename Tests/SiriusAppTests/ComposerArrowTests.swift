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

import Foundation
import XCTest
@testable import SiriusCore

final class AccessibilityContextTests: XCTestCase {
    private func app(_ id: String) throws -> NativeApp { try XCTUnwrap(NativeApps.app(id)) }

    private func snapshot(_ reading: AccessibilityReading, _ id: String) throws -> AmbientSnapshot? {
        AccessibilityContext.snapshot(reading, app: try app(id), pid: 42, instance: "run")
    }

    func testADocumentWithSelectedTextIsTheTreeAProviderWouldSend() throws {
        let reading = AccessibilityReading(
            windowTitle: "report.pdf – 3 pages", documentURL: "file:///tmp/report.pdf", selectedText: "two words")
        let answer = try XCTUnwrap(try snapshot(reading, "com.apple.Preview"))
        let root = answer.tree.root
        XCTAssertEqual(root.role, "Application")
        XCTAssertEqual(root.attributes?["source"], .string("accessibility"))
        XCTAssertEqual(answer.tree.focusPath.map(\.role), ["Window", "Document", "Text"])
        let document = answer.tree.focusPath[1]
        XCTAssertEqual(document.subrole, "pdf")
        XCTAssertEqual(document.title, "report.pdf")
        XCTAssertEqual(document.url, "file:///tmp/report.pdf")
        XCTAssertEqual(answer.tree.selected.map(\.text), ["two words"])
        XCTAssertEqual(answer.summary, AmbientSummary(subject: "report.pdf", selection: "“two words”"))
        XCTAssertEqual(answer.appName, "Preview")
        XCTAssertEqual(answer.source, "com.apple.Preview")
        XCTAssertTrue(answer.provider.isNative)
        XCTAssertNil(answer.helper)
    }

    func testAPageKeepsItsOwnTitleAndAddress() throws {
        let reading = AccessibilityReading(
            windowTitle: "Window", documentURL: "https://example.com/a", documentTitle: "A page", selectedText: "x")
        let answer = try XCTUnwrap(try snapshot(reading, "com.apple.Safari"))
        XCTAssertEqual(answer.tree.focusPath[1].title, "A page")
        XCTAssertEqual(answer.tree.focusPath[1].url, "https://example.com/a")
        XCTAssertEqual(answer.summary, AmbientSummary(subject: "A page", selection: "“x”"))
    }

    func testAnOpenDocumentWithNothingSelectedIsStillSent() throws {
        let answer = try XCTUnwrap(try snapshot(AccessibilityReading(windowTitle: "Shopping"), "com.apple.Notes"))
        XCTAssertEqual(answer.tree.focusPath.map(\.role), ["Window", "Document"])
        XCTAssertTrue(answer.tree.selected.isEmpty)
        XCTAssertEqual(answer.summary, AmbientSummary(subject: "Shopping"))
    }

    func testNothingReportedIsNoContext() throws {
        XCTAssertNil(try snapshot(AccessibilityReading(), "com.apple.Preview"))
        XCTAssertNil(try snapshot(AccessibilityReading(windowTitle: "  ", selectedText: "\n"), "com.apple.Notes"))
        XCTAssertNil(try snapshot(AccessibilityReading(), "com.apple.finder"))
        XCTAssertNil(try snapshot(AccessibilityReading(), "com.apple.MobileSMS"))
    }

    func testSelectedFilesAreRowsWithTheirAddresses() throws {
        let reading = AccessibilityReading(windowTitle: "Downloads", items: [
            .init(title: "a.txt", url: "file:///d/a.txt"), .init(title: "b.txt", url: "file:///d/b.txt"), .init(),
        ])
        let answer = try XCTUnwrap(try snapshot(reading, "com.apple.finder"))
        let rows = answer.tree.selected
        XCTAssertEqual(rows.map(\.role), ["Row", "Row"])
        XCTAssertEqual(rows.map(\.url), ["file:///d/a.txt", "file:///d/b.txt"])
        XCTAssertEqual(answer.summary, AmbientSummary(subject: "Downloads", selection: "2 selected"))

        let one = AccessibilityReading(windowTitle: "Downloads", items: [.init(title: "a.txt", url: "file:///d/a.txt")])
        XCTAssertEqual(try XCTUnwrap(try snapshot(one, "com.apple.finder")).summary,
                       AmbientSummary(subject: "Downloads", selection: "a.txt"))
    }

    func testAConversationsSelectionIsOneMessage() throws {
        let reading = AccessibilityReading(windowTitle: "Ada", selectedText: "see you at six")
        let answer = try XCTUnwrap(try snapshot(reading, "com.apple.MobileSMS"))
        XCTAssertEqual(answer.tree.focusPath.map(\.role), ["Window", "List", "Row", "Text"])
        XCTAssertEqual(answer.tree.focusPath[1].subrole, "conversation")
        XCTAssertEqual(answer.summary, AmbientSummary(subject: "Ada", selection: "“see you at six”"))
    }

    // The line quotes how the selection begins, cut at a word.
    func testTheLineQuotesTheStartOfTheSelection() throws {
        let text = "The Tenant shall give no less than sixty (60) days' written notice.\nSecond line."
        let answer = try XCTUnwrap(try snapshot(AccessibilityReading(windowTitle: "n", selectedText: text), "com.apple.Notes"))
        XCTAssertEqual(answer.summary.selection, "“The Tenant shall give no…”")
        XCTAssertEqual(AmbientSummary.excerpt("  one\n\ttwo  "), "“one two”")
        XCTAssertEqual(AmbientSummary.excerpt(String(repeating: "a", count: 40)),
                       "“" + String(repeating: "a", count: AmbientSummary.excerptChars) + "…”")
        XCTAssertNil(AmbientSummary.excerpt(" \n "))
        XCTAssertNil(AmbientSummary.excerpt(nil))
    }

    func testSelectedTextIsCapped() throws {
        let long = String(repeating: "a", count: AccessibilityContext.maxTextChars + 10)
        let answer = try XCTUnwrap(try snapshot(AccessibilityReading(windowTitle: "n", selectedText: long), "com.apple.Notes"))
        XCTAssertEqual(answer.tree.selected.first?.text?.count, AccessibilityContext.maxTextChars)
    }

    func testEveryIdInTheTreeIsItsOwn() throws {
        let reading = AccessibilityReading(windowTitle: "D", items: (1...60).map { .init(title: "f\($0)") })
        let answer = try XCTUnwrap(try snapshot(reading, "com.apple.finder"))
        let ids = answer.tree.root.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(answer.tree.selected.count, AccessibilityContext.maxItems)
    }

    func testTheListAndItsDefaults() throws {
        XCTAssertEqual(NativeApps.all.map(\.name), ["Preview", "Notes", "Safari", "Finder", "Mail", "Messages"])
        XCTAssertNil(NativeApps.app("com.google.Chrome"))
        let suite = "sirius-native-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NativeApps.all.filter { NativeApps.isOn($0, in: defaults) }.map(\.name),
                       ["Preview", "Notes", "Safari", "Finder"])
        XCTAssertEqual(NativeApps.all.filter(\.asks).map(\.name), ["Mail"])
        let messages = try app("com.apple.MobileSMS"), preview = try app("com.apple.Preview")
        defaults.set(true, forKey: NativeApps.key(messages))
        defaults.set(false, forKey: NativeApps.key(preview))
        XCTAssertTrue(NativeApps.isOn(messages, in: defaults))
        XCTAssertFalse(NativeApps.isOn(preview, in: defaults))
    }

    func testApplesRolesMapOntoTheProtocols() {
        XCTAssertEqual(AccessibilityContext.role(forApple: "AXTextArea"), "Text")
        XCTAssertEqual(AccessibilityContext.role(forApple: "AXWebArea"), "Document")
        XCTAssertEqual(AccessibilityContext.role(forApple: "AXOutline"), "List")
        XCTAssertEqual(AccessibilityContext.role(forApple: "AXScrollBar"), "Group")
        for role in ["AXWindow", "AXRow", "AXCell", "AXLink", "AXImage", "AXHeading", "AXTable", "AXApplication"] {
            XCTAssertTrue(AmbientElement.roles.contains(AccessibilityContext.role(forApple: role)))
        }
    }
}

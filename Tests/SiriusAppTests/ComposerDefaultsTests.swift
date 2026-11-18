import AppKit
import XCTest
import SiriusCore
import SiriusProtocol
@testable import SiriusApp

// The composer remembers its agent in the defaults it was given, not in
// the user's own.
@MainActor
final class ComposerDefaultsTests: XCTestCase {
    private final class NoTarget: ComposerTarget {
        func composerAgents() async -> [ComposerAgent] { [] }
        func send(text: String, attachments: [URL], context: Message.Context?, to agent: String) async throws {}
    }

    func testTheRememberedAgentIsReadFromTheGivenDefaults() throws {
        let suite = "sirius-composer-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("only-in-this-suite", forKey: SettingsKeys.lastAgent)

        let composer = ComposerController(target: NoTarget(), defaults: defaults)
        XCTAssertEqual(composer.currentAgent, "only-in-this-suite")
    }
}

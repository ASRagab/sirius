import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// An aside with a tool call against each real harness: the fork streams
// its turn as TurnEvents, a tool call opens and reaches a final status,
// and nothing is left open. Needs a build (for the helpers) but no Sirius.app. Gated, two short turns per
// harness:
//   SIRIUS_LIVE_ASIDE=claude,codex,muse swift test --filter AsideLiveTests
final class AsideLiveTests: XCTestCase {
    func testClaude() async throws {
        try await run("claude") { registration, root, aside in
            ClaudeAdapter(registration: registration, socketPath: "/nonexistent.sock", helpersDirectory: root,
                          named: false, aside: aside)
        }
    }

    func testCodex() async throws {
        try await run("codex") { registration, root, aside in
            CodexAdapter(registration: registration, socketPath: "/nonexistent.sock", helpersDirectory: root,
                         aside: aside)
        }
    }

    func testMuse() async throws {
        try await run("muse") { registration, root, aside in
            MuseAdapter(registration: registration, socketPath: "/nonexistent.sock", helpersDirectory: root,
                        aside: aside)
        }
    }

    private func run(_ harness: String,
                     make: @escaping @Sendable (AgentRegistration, URL, AsideOptions?) -> any Adapter) async throws {
        let asked = (ProcessInfo.processInfo.environment["SIRIUS_LIVE_ASIDE"] ?? "").split(separator: ",").map(String.init)
        guard asked.contains(harness) else {
            throw XCTSkip("set SIRIUS_LIVE_ASIDE=\(harness) to run an aside against the real harness")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aside-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "The password is HERON.\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let registration: AgentRegistration
        switch harness {
        case "claude":
            registration = AgentRegistration(agent: "dev", name: "Dev", harness: .claudeCode, executable: "",
                                             root: root.path, model: "claude-haiku-5-5")
        case "codex":
            registration = AgentRegistration(agent: "dev", name: "Dev", harness: .codex, executable: "", root: root.path)
        default:
            registration = AgentRegistration(agent: "dev", name: "Dev", harness: .museCode, executable: "",
                                             root: root.path, model: "muse-wonder-1.0", effort: "low")
        }

        // The main session needs its helpers: Muse fails a turn whose sirius
        // MCP server cannot start.
        let helpers = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug")
        let main = make(registration, helpers, nil)
        _ = try await main.open(SessionRequest())
        let first = try await main.prompt(Message(id: "m_live1", agent: "dev",
                                                   text: "Remember the word PELICAN. Reply only OK, no tools."))
        XCTAssertEqual(first.outcome, .completed)
        let parent = try XCTUnwrap(first.session)

        let said = AsideText()
        let aside = AsideSession(agent: "dev", parent: parent) { options in
            make(registration, helpers, AsideOptions(instructions: options.instructions, onEvent: {
                said.append($0)
                options.onEvent($0)
            }))
        }
        await aside.send("Run a shell command to read notes.txt in this folder, then tell me the password in it and the word I asked you to remember, in one sentence.")
        var ended: AsideSession.Event?
        for await event in aside.events {
            if case .turnEnded = event { ended = event; break }
        }
        for line in TurnEventTrace.lines(said.events) { print("live[\(harness)]: \(line)") }
        await aside.close()
        await main.close()

        XCTAssertEqual(ended, .turnEnded(failure: nil))
        XCTAssertEqual(TurnEventTrace.unended(said.events), [])
        XCTAssertTrue(said.events.contains { if case .toolCall = $0 { return true } else { return false } },
                      "no tool call was heard")
        XCTAssertTrue(said.joined.uppercased().contains("HERON"), said.joined)
        XCTAssertTrue(said.joined.uppercased().contains("PELICAN"), said.joined)
    }
}

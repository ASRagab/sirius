import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// The real `claude` against the running Sirius.app's dev socket. Gated:
//   SIRIUS_LIVE_CLAUDE=1 swift test --filter ClaudeLiveTests
// Shows two real toasts and spends two short model turns.
final class ClaudeLiveTests: XCTestCase {
    // Consolidation against the real CLI: one short turn, then /compact
    // with the brief; the session carries on. Needs no Sirius.app.
    //   SIRIUS_LIVE_CLAUDE=1 swift test --filter testConsolidateShrinksTheContext
    func testConsolidateShrinksTheContext() async throws {
        guard ProcessInfo.processInfo.environment["SIRIUS_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("set SIRIUS_LIVE_CLAUDE=1 to run against the real claude")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: .claudeCode, executable: "",
                                             root: root.path, model: "claude-haiku-5-5")
        let adapter = ClaudeAdapter(registration: registration, socketPath: "/nonexistent.sock",
                                    helpersDirectory: root, named: false)
        _ = try await adapter.open(SessionRequest())
        let first = try await adapter.prompt(Message(id: "m_live1", agent: "dev",
                                                      text: "Remember the word PELICAN. Reply only OK, no tools."))
        XCTAssertEqual(first.outcome, .completed)
        let context = await adapter.contextTokens()
        let before = try XCTUnwrap(context)
        let consolidation = try await adapter.compact()
        let done = try XCTUnwrap(consolidation)
        print("live: consolidated \(done)")
        XCTAssertEqual(done.outcome, .completed)
        // Claude's own count, which takes in the last reply too.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(done.before), before)
        XCTAssertLessThan(try XCTUnwrap(done.after), before)
        let next = try await adapter.prompt(Message(id: "m_live2", agent: "dev", text: "Reply only OK."))
        XCTAssertEqual(next.outcome, .completed)
        XCTAssertEqual(next.session, first.session, "same session after the compaction")
        await adapter.close()
    }

    // An aside against the real CLI: a fork of a session knows what the
    // session knew, streams its answer as text, and leaves the session its
    // own id. Needs no Sirius.app; spends three short turns.
    //   SIRIUS_LIVE_CLAUDE=1 swift test --filter testAnAsideForksAndStreams
    func testAnAsideForksAndStreams() async throws {
        guard ProcessInfo.processInfo.environment["SIRIUS_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("set SIRIUS_LIVE_CLAUDE=1 to run against the real claude")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: .claudeCode, executable: "",
                                             root: root.path, model: "claude-haiku-5-5")
        let main = ClaudeAdapter(registration: registration, socketPath: "/nonexistent.sock",
                                 helpersDirectory: root, named: false)
        _ = try await main.open(SessionRequest())
        let first = try await main.prompt(Message(id: "m_live1", agent: "dev",
                                                   text: "Remember the word PELICAN. Reply only OK, no tools."))
        let parent = try XCTUnwrap(first.session)

        let said = AsideText()
        let started = Date()
        let aside = AsideSession(agent: "dev", parent: parent) { options in
            ClaudeAdapter(registration: registration, socketPath: "/nonexistent.sock", helpersDirectory: root,
                          named: false, aside: AsideOptions(instructions: options.instructions, onEvent: {
                              if case .textDelta = $0, said.pieces.isEmpty {
                                  print("live: first text after \(Date().timeIntervalSince(started)) s")
                              }
                              said.append($0)
                              options.onEvent($0)
                          }))
        }
        await aside.send("Which word did I ask you to remember? Answer in one short sentence.")
        var ended: AsideSession.Event?
        for await event in aside.events {
            if case .turnEnded = event { ended = event; break }
        }
        print("live: aside said \(said.pieces.count) pieces: \(said.joined)")
        XCTAssertEqual(ended, .turnEnded(failure: nil))
        XCTAssertTrue(said.joined.uppercased().contains("PELICAN"), said.joined)
        let forked = await aside.session
        XCTAssertNotNil(forked)
        XCTAssertNotEqual(forked, parent, "the aside has a session of its own")

        // A longer answer arrives over time, not in one burst at its end.
        let before = said.pieces.count
        let longStarted = Date()
        await aside.send("Write about 150 words on why the sea is salty. Plain prose, no tools.")
        var arrivals: [TimeInterval] = []
        for await event in aside.events {
            if case .event(.textDelta) = event { arrivals.append(Date().timeIntervalSince(longStarted)) }
            if case .turnEnded = event { break }
        }
        let spread = (arrivals.last ?? 0) - (arrivals.first ?? 0)
        print("live: long answer in \(said.pieces.count - before) pieces, first \(arrivals.first ?? -1) s, last \(arrivals.last ?? -1) s")
        XCTAssertGreaterThan(arrivals.count, 10)
        XCTAssertGreaterThan(spread, 0.5, "the answer's text came in one burst")
        await aside.close()

        // The main session goes on as itself and never heard the aside.
        let next = try await main.prompt(Message(id: "m_live2", agent: "dev", text: "Reply only OK."))
        XCTAssertEqual(next.outcome, .completed)
        XCTAssertEqual(next.session, parent)
        await main.close()
    }

    func testToastThenResume() async throws {
        guard ProcessInfo.processInfo.environment["SIRIUS_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("set SIRIUS_LIVE_CLAUDE=1 to run against the real claude and Sirius.app")
        }
        let socket = Self.userTempDirectory() + "sirius/dev.sock"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socket), "Sirius.app is not serving \(socket)")
        let helpers = try XCTUnwrap(Self.helpersDirectory(), "no sirius helper built or installed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let events = EventRecorder()
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: .claudeCode,
                                             executable: "", root: root.path)
        let adapter = ClaudeAdapter(registration: registration, socketPath: socket, helpersDirectory: helpers,
                                    observer: { events.append($0) })
        print("live: helpers \(helpers.path), socket \(socket), root \(root.path)")

        let started = try await adapter.open(SessionRequest())
        print("live: start returned \(started)")
        let first = try await adapter.prompt(Message(id: "m_live1", agent: "dev",
                                                      text: "Show me a toast saying \"T12 live check\"."))
        print("live: turn 1 \(first)")
        events.dump(label: "turn 1")
        XCTAssertEqual(first.outcome, .completed)
        let session = try XCTUnwrap(first.session)
        XCTAssertTrue(events.succeededToast(), "a Bash `sirius display toast` call succeeded")
        await adapter.close()

        events.clear()
        let resumed = try await adapter.open(SessionRequest(resume: session))
        print("live: restart returned \(resumed)")
        let args = await adapter.launchArguments
        print("live: args \(args)")
        let i = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(args[i + 1], session)
        let second = try await adapter.prompt(Message(id: "m_live2", agent: "dev",
                                                       text: "What did I ask you a moment ago? Reply via toast."))
        print("live: turn 2 \(second)")
        events.dump(label: "turn 2")
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertEqual(second.session, session)
        XCTAssertTrue(events.succeededToast(), "the resumed turn replied via toast")
        await adapter.close()
    }

    private static func userTempDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    }

    // This worktree's build, else the installed app's.
    private static func helpersDirectory() -> URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [repo.appendingPathComponent(".build/debug"),
                          URL(fileURLWithPath: "/Applications/Sirius.app/Contents/Helpers")]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("sirius").path)
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func append(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
    }

    private var objects: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func blocks(_ event: [String: Any]) -> [[String: Any]] {
        (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    // A Bash tool_use running `sirius display toast` whose tool_result is not an error.
    func succeededToast() -> Bool {
        let events = objects
        var toastCalls: Set<String> = []
        for event in events where event["type"] as? String == "assistant" {
            for block in blocks(event) where block["type"] as? String == "tool_use" && block["name"] as? String == "Bash" {
                let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
                if command.contains("sirius display toast"), let id = block["id"] as? String { toastCalls.insert(id) }
            }
        }
        for event in events where event["type"] as? String == "user" {
            for block in blocks(event) where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String, toastCalls.contains(id), block["is_error"] as? Bool != true {
                    return true
                }
            }
        }
        return false
    }

    func dump(label: String) {
        for event in objects {
            let type = (event["type"] as? String ?? "?") + ((event["subtype"] as? String).map { "/\($0)" } ?? "")
            var detail = ""
            if type == "system/init" {
                detail = "session_id=\(event["session_id"] ?? "-") model=\(event["model"] ?? "-")"
            }
            for block in blocks(event) {
                switch block["type"] as? String {
                case "tool_use":
                    detail += " tool_use \(block["name"] ?? "?"): \((block["input"] as? [String: Any])?["command"] ?? "")"
                case "tool_result":
                    detail += " tool_result is_error=\(block["is_error"] ?? "nil"): \(String(describing: block["content"] ?? "").prefix(200))"
                case "text":
                    detail += " text: \(String(describing: block["text"] ?? "").prefix(200))"
                default: break
                }
            }
            if type.hasPrefix("result") {
                detail = "is_error=\(event["is_error"] ?? "-") session_id=\(event["session_id"] ?? "-") num_turns=\(event["num_turns"] ?? "-") duration_ms=\(event["duration_ms"] ?? "-") permission_denials=\(event["permission_denials"] ?? "-")"
            }
            print("live[\(label)]: \(type) \(detail)")
        }
    }
}

import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// The real `muse serve` against the running Sirius.app's dev socket. Gated:
//   SIRIUS_LIVE_MUSE=1 swift test --filter MuseLiveTests
// Shows two real toasts and spends two low-effort Muse turns, about 8% of
// an Everyday Usage 5-hour window.
final class MuseLiveTests: XCTestCase {
    func testToastThenResume() async throws {
        guard ProcessInfo.processInfo.environment["SIRIUS_LIVE_MUSE"] == "1" else {
            throw XCTSkip("set SIRIUS_LIVE_MUSE=1 to run against the real muse and Sirius.app")
        }
        let socket = Self.userTempDirectory() + "sirius/dev.sock"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socket), "Sirius.app is not serving \(socket)")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helpers = repo.appendingPathComponent(".build/debug")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("sirius-mcp").path),
                          "no sirius-mcp built")
        let tools = try String(contentsOf: repo.appendingPathComponent("packaging/agent/muse-code/tools.md"),
                               encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = LineRecorder()
        let registration = AgentRegistration(agent: "dev", name: "Dev", harness: .museCode, executable: "",
                                             root: root.path, model: "muse-wonder-1.0", effort: "low")
        let instructions = "You are an agent in Sirius. The user reads only what you send through these tools:\n" + tools
        func makeAdapter() async -> MuseAdapter {
            let adapter = MuseAdapter(registration: registration, socketPath: socket, helpersDirectory: helpers,
                                      instructions: instructions)
            await adapter.observe { lines.append($0) }
            return adapter
        }

        let adapter = await makeAdapter()
        let opened = try await adapter.open(SessionRequest())
        print("live: open \(opened)")
        let first = try await adapter.prompt(Message(id: "m_live1", agent: "dev",
                                                      text: "Show me a toast saying \"Muse live check\"."))
        print("live: turn 1 \(first)")
        lines.dumpTools(label: "turn 1")
        XCTAssertEqual(first.outcome, .completed)
        XCTAssertTrue(lines.calledDisplay(), "turn 1 called the sirius display tool")
        let session = try XCTUnwrap(first.session)
        await adapter.close()

        lines.clear()
        let resumed = await makeAdapter()
        let reopened = try await resumed.open(SessionRequest(resume: session))
        XCTAssertEqual(reopened.session, session)
        let second = try await resumed.prompt(Message(id: "m_live2", agent: "dev",
                                                       text: "What did I ask you a moment ago? Reply via toast."))
        print("live: turn 2 \(second)")
        lines.dumpTools(label: "turn 2")
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertTrue(lines.calledDisplay(), "the resumed turn replied via toast")
        await resumed.close()
    }

    private static func userTempDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func clear() { lock.withLock { lines.removeAll() } }

    // Completed tool calls of the sirius MCP server's display tool.
    private var toolItems: [String] {
        lock.withLock { lines }.filter {
            $0.hasPrefix("<< ") && $0.contains("\"item/completed\"") && $0.contains("\"kind\":\"toolCall\"")
                && $0.contains("mcp__sirius__display") && $0.contains("\"status\":\"completed\"")
        }
    }

    func calledDisplay() -> Bool { !toolItems.isEmpty }

    func dumpTools(label: String) {
        for line in toolItems { print("live[\(label)]: \(line.prefix(600))") }
        let failures = lock.withLock { lines }.filter { $0.contains("\"turn/completed\"") }
        for line in failures { print("live[\(label)]: \(line.prefix(400))") }
    }
}

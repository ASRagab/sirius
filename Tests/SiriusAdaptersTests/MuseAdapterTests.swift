import Darwin
import Foundation
import SiriusCore
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

final class MuseAdapterTests: XCTestCase {
    private var root: URL!
    private var adapter: MuseAdapter!

    static let instructions = "Reply through Sirius.\nUse \"sirius\"."

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        adapter = try makeAdapter(model: "muse-wonder-1.0", effort: "low")
    }

    private func makeAdapter(model: String?, effort: String? = nil) throws -> MuseAdapter {
        let executable = try MuseFakeServe.install(in: root)
        let registration = AgentRegistration(agent: "mu", name: "Muse", harness: .museCode,
                                             executable: executable, root: root.path, model: model, effort: effort)
        return MuseAdapter(registration: registration, socketPath: "/tmp/sirius-test/mu.sock",
                           helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"),
                           instructions: Self.instructions)
    }

    override func tearDown() async throws {
        await adapter?.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func received() -> [[String: Any]] { MuseFakeServe.received(in: root) }

    private func methods() -> [String] { received().compactMap { $0["method"] as? String } }

    private func request(_ method: String) -> [String: Any]? {
        received().last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    private func waitFor(_ method: String) async throws {
        for _ in 0..<300 {
            if methods().contains(method) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("\(method) never arrived")
    }

    func testOpenStartsAnAllowAllSessionWithSiriusMCP() async throws {
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.session, "session-new")
        XCTAssertEqual(info.model, "muse-wonder-1.0")
        XCTAssertEqual(info.effort, "low")
        XCTAssertEqual(info.capabilities, AgentCapabilities(steer: true, agentTurns: true, usage: true))

        // initialized only after initialize has returned.
        XCTAssertEqual(Array(methods().prefix(3)), ["initialize", "initialized", "model/list"])
        let initialize = try XCTUnwrap(request("initialize"))
        XCTAssertEqual((initialize["clientInfo"] as? [String: Any])?["name"] as? String, "sirius")
        XCTAssertEqual((initialize["capabilities"] as? [String: Any])?["requestedCapabilities"] as? [String],
                       ["sessionMcp"])

        let start = try XCTUnwrap(request("session/start"))
        XCTAssertEqual(start["approvalMode"] as? String, "allowAll")
        XCTAssertEqual(start["workspaceRoot"] as? String, root.path)
        XCTAssertEqual(start["modelId"] as? String, "muse-wonder-1.0")
        XCTAssertNotNil(start["commandId"] as? String)
        let mcp = try XCTUnwrap(((start["config"] as? [String: Any])?["mcpServers"] as? [String: Any])?["sirius"]
            as? [String: Any])
        XCTAssertEqual(mcp["transport"] as? String, "stdio")
        XCTAssertEqual(mcp["command"] as? String, "/opt/sirius/Helpers/sirius-mcp")
        XCTAssertEqual((mcp["env"] as? [String: String])?["SIRIUS_SOCKET"], "/tmp/sirius-test/mu.sock")
    }

    func testTheHostIsLaunchedForSirius() async throws {
        _ = try await adapter.open(SessionRequest())
        let launched = try XCTUnwrap(MuseFakeServe.arguments(in: root))
        let argv = try XCTUnwrap(launched["argv"] as? [String])
        XCTAssertEqual(Array(argv.prefix(5)), ["serve", "--provider", "meta", "--model", "muse-wonder-1.0"])
        for flag in ["--disable-request-user-input", "--trust-workspace"] { XCTAssertTrue(argv.contains(flag), flag) }
        XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--contributor-mode")) + 1], "off")
        XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--sandbox-network")) + 1], "enabled")
        let config = argv[try XCTUnwrap(argv.firstIndex(of: "-c")) + 1]
        XCTAssertEqual(config, #"run.developer_prompt="Reply through Sirius.\nUse \"sirius\".""#)
        XCTAssertEqual(launched["socket"] as? String, "/tmp/sirius-test/mu.sock")
        XCTAssertEqual(launched["noUpdate"] as? String, "1")
        XCTAssertTrue((launched["path"] as? String)?.hasPrefix("/opt/sirius/Helpers:") == true)
    }

    func testResumePassesTheSessionAndAGoneOneIsReplaced() async throws {
        let resumed = try await adapter.open(SessionRequest(resume: "s-old"))
        XCTAssertEqual(resumed.session, "s-old")
        let resume = try XCTUnwrap(request("session/resume"))
        XCTAssertEqual(resume["sessionId"] as? String, "s-old")
        XCTAssertEqual(resume["excludeItems"] as? Bool, true)
        XCTAssertNotNil((resume["config"] as? [String: Any])?["mcpServers"])

        let replaced = try await adapter.open(SessionRequest(resume: "missing"))
        XCTAssertEqual(replaced.session, "session-new")
    }

    func testAPromptCompletesTheTurnWithItsImages() async throws {
        let image = root.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        _ = try await adapter.open(SessionRequest())
        let message = Message(id: "m_1", agent: "mu", text: "hello",
                              attachments: [.init(path: image.path, mimeType: "image/png"),
                                            .init(path: "/a/notes.txt", mimeType: "text/plain")])
        let end = try await adapter.prompt(message)
        XCTAssertEqual(end, TurnEnd(session: "session-new", outcome: .completed, model: "muse-wonder-1.0"))

        let turn = try XCTUnwrap(request("turn/start"))
        XCTAssertEqual(turn["sessionId"] as? String, "session-new")
        XCTAssertEqual(turn["reasoningEffort"] as? String, "low")
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["text"] as? String, MessageRenderer.render(message))
        XCTAssertEqual(input[1]["type"] as? String, "image")
        XCTAssertEqual(input[1]["mediaType"] as? String, "image/png")
        XCTAssertEqual(input[1]["base64Data"] as? String, "iVBORw==")

        let second = try await adapter.prompt(Message(id: "m_2", agent: "mu", text: "again"))
        XCTAssertEqual(second.outcome, .completed)
    }

    func testAFailedTurnIsReportedAndTheAgentStaysUp() async throws {
        _ = try await adapter.open(SessionRequest())
        let end = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_FAIL"))
        XCTAssertEqual(end.outcome, .failed("boom"))
        let next = try await adapter.prompt(Message(id: "m_2", agent: "mu", text: "fine"))
        XCTAssertEqual(next.outcome, .completed)
    }

    func testUsageIsReported() async throws {
        let updates = adapter.updates
        _ = try await adapter.open(SessionRequest())
        _ = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "hello"))
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .usage(contextTokens: 28001))
    }

    // A turn the agent starts itself (a background task finishing) is
    // reported once it ends; the reminder child sessions are not.
    func testAnAgentTurnIsReportedAndChildSessionsAreNot() async throws {
        let updates = adapter.updates
        _ = try await adapter.open(SessionRequest())
        _ = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_AGENT"))
        var ended: [TurnEnd] = []
        let collect = Task {
            var out: [TurnEnd] = []
            for await update in updates {
                if case .agentTurnEnded(let end) = update { out.append(end) }
                if out.count == 1 { break }
            }
            return out
        }
        let timeout = Task { try await Task.sleep(nanoseconds: 3_000_000_000); collect.cancel() }
        ended = await collect.value
        timeout.cancel()
        XCTAssertEqual(ended, [TurnEnd(session: "session-new", outcome: .completed, model: "muse-wonder-1.0")])
    }

    func testAnApprovalIsGrantedOnceAndUserInputIsCancelled() async throws {
        _ = try await adapter.open(SessionRequest())
        let approved = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_APPROVAL"))
        XCTAssertEqual(approved.outcome, .completed)
        let receipt = received().first { ($0["id"] as? Int) == 900 && $0["method"] == nil }
        XCTAssertEqual((receipt?["result"] as? [String: Any])?.count, 0, "an empty receipt")
        let decide = try XCTUnwrap(request("approval/decide"))
        XCTAssertEqual(decide["choiceId"] as? String, "yes")
        XCTAssertEqual(decide["approvalId"] as? String, "ap-1")
        XCTAssertEqual((decide["requirementId"] as? [String: Any])?["approvalId"] as? String, "ap-1")

        let answered = try await adapter.prompt(Message(id: "m_2", agent: "mu", text: "FAKE_INPUT"))
        XCTAssertEqual(answered.outcome, .completed)
        XCTAssertEqual(request("userInput/cancel")?["userInputId"] as? String, "ui-1")
    }

    func testASteerJoinsTheRunningTurnAndNeedsOne() async throws {
        _ = try await adapter.open(SessionRequest())
        let idle = await adapter.steer(Message(id: "m_0", agent: "mu", text: "nobody is listening"))
        XCTAssertEqual(idle, .notJoined)
        let adapter = self.adapter!
        let turn = Task { try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_HOLD")) }
        try await waitFor("turn/start")
        var joined = SteerResult.notJoined
        for _ in 0..<200 where joined == .notJoined {
            joined = await adapter.steer(Message(id: "m_2", agent: "mu", text: "also this"))
            if joined == .notJoined { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertEqual(joined, .joined)
        let steer = try XCTUnwrap(request("turn/steer"))
        XCTAssertEqual(steer["expectedTurnId"] as? String, "turn-1")
        XCTAssertEqual(steer["sessionId"] as? String, "session-new")
        let done = await adapter.steer(Message(id: "m_3", agent: "mu", text: "FAKE_DONE"))
        XCTAssertEqual(done, .joined)
        let end = try await turn.value
        XCTAssertEqual(end.outcome, .completed)
        let after = await adapter.steer(Message(id: "m_4", agent: "mu", text: "too late"))
        XCTAssertEqual(after, .notJoined)
    }

    func testProcessExitMidTurnThrows() async throws {
        _ = try await adapter.open(SessionRequest())
        do {
            _ = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_EXIT"))
            XCTFail("prompt returned")
        } catch is CancellationError {
            XCTFail("a lost process is not a cancellation")
        } catch {
            XCTAssertTrue(error is MuseServeError, "\(error)")
        }
        await adapter.close()
        let session = try await adapter.open(SessionRequest(resume: "session-new")).session
        XCTAssertEqual(session, "session-new")
    }

    func testCloseMidTurnCancelsThePromptAndEndsTheProcess() async throws {
        _ = try await adapter.open(SessionRequest())
        let running = await adapter.processIdentifier
        let pid = try XCTUnwrap(running)
        XCTAssertEqual(kill(pid, 0), 0)
        let adapter = self.adapter!
        let turn = Task { try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_HANG")) }
        try await waitFor("turn/start")
        await adapter.close()
        XCTAssertNotEqual(kill(pid, 0), 0)
        do {
            _ = try await turn.value
            XCTFail("prompt returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await adapter.close()
    }

    func testAModelNotOnTheTierIsRefusedAtOpen() async throws {
        adapter = try makeAdapter(model: "muse-wonder-full-1.0")
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("expected a throw")
        } catch let error as MuseAdapterError {
            XCTAssertEqual(error, .modelUnavailable("muse-wonder-full-1.0", available: ["muse-wonder-1.0", "muse-spark-1.2"]))
            XCTAssertEqual(error.userMessage,
                           "muse-wonder-full-1.0 isn't included in your Muse plan. Pick another model for this agent.")
        }
        XCTAssertFalse(methods().contains("session/start"))
        let pid = await adapter.processIdentifier
        XCTAssertNil(pid)
    }

    func testWithoutAModelMusesDefaultIsReported() async throws {
        adapter = try makeAdapter(model: nil)
        let info = try await adapter.open(SessionRequest())
        XCTAssertEqual(info.model, "muse-spark-1.2")
        XCTAssertFalse(methods().contains("model/list"))
    }

    func testAnOldMuseOrAnotherSchemaIsRefused() async throws {
        try MuseFakeServe.set("fake-muse.init", "old", in: root)
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("expected a throw")
        } catch let error as MuseAdapterError {
            XCTAssertEqual(error, .tooOld(version: "1.4.6"))
        }
        try MuseFakeServe.set("fake-muse.init", "schema2", in: root)
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("expected a throw")
        } catch let error as MuseAdapterError {
            XCTAssertEqual(error, .unsupportedSchema(2))
        }
    }

    func testAMuseThatQuitsAtInitializeSaysWhy() async throws {
        try MuseFakeServe.set("fake-muse.init", "exit", in: root)
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("expected a throw")
        } catch let error as MuseAdapterError {
            guard case .startFailed(let line, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(line, "Error: not signed in: run `muse login`")
            XCTAssertTrue(reason.contains("muse serve"), reason)
        }
        try MuseFakeServe.set("fake-muse.init", "error", in: root)
        do {
            _ = try await adapter.open(SessionRequest())
            XCTFail("expected a throw")
        } catch let error as MuseAdapterError {
            XCTAssertEqual(error.userMessage, "Muse Code quit as it started: clientInfo.name: invalid")
        }
    }

    func testPromptBeforeOpenThrows() async throws {
        do {
            _ = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "hi"))
            XCTFail("prompt returned")
        } catch {
            XCTAssertEqual(error as? MuseAdapterError, .notStarted)
        }
    }

    // MARK: Asides

    static let asideInstructions = "Answer here, in your own words."

    private func asideAdapter(_ text: AsideText) throws -> MuseAdapter {
        let executable = try MuseFakeServe.install(in: root)
        let registration = AgentRegistration(agent: "mu", name: "Muse", harness: .museCode,
                                             executable: executable, root: root.path, model: "muse-wonder-1.0")
        var env = ProcessInfo.processInfo.environment
        env["SIRIUS_SOCKET"] = "/tmp/inherited.sock"
        return MuseAdapter(registration: registration, socketPath: "/tmp/sirius-test/mu.sock",
                           helpersDirectory: URL(fileURLWithPath: "/opt/sirius/Helpers"),
                           instructions: Self.instructions, environment: env,
                           aside: AsideOptions(instructions: Self.asideInstructions, onEvent: { text.append($0) }))
    }

    func testAForkedAsideOpensItsOwnSessionAllowingAll() async throws {
        adapter = try asideAdapter(AsideText())
        let info = try await adapter.open(SessionRequest(resume: "s-old", fork: true))
        XCTAssertEqual(info.session, "fork-of-s-old", "the fork's id, not the parent's")
        let opening = methods().filter { $0.hasPrefix("session/") }
        XCTAssertEqual(opening, ["session/fork", "session/setApprovalMode"])
        let fork = try XCTUnwrap(request("session/fork"))
        XCTAssertEqual(fork["sessionId"] as? String, "s-old")
        XCTAssertEqual(fork["excludeItems"] as? Bool, true)
        XCTAssertNotNil(fork["commandId"] as? String)
        let mode = try XCTUnwrap(request("session/setApprovalMode"))
        XCTAssertEqual(mode["sessionId"] as? String, "fork-of-s-old")
        XCTAssertEqual(mode["mode"] as? String, "allowAll")
        let end = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "hi"))
        XCTAssertEqual(end, TurnEnd(session: "fork-of-s-old", outcome: .completed, model: "muse-wonder-1.0"))
        XCTAssertEqual(request("turn/start")?["sessionId"] as? String, "fork-of-s-old")
    }

    func testARefusedForkStartsAnEmptySessionWithoutSiriusMCP() async throws {
        adapter = try asideAdapter(AsideText())
        let info = try await adapter.open(SessionRequest(resume: "missing", fork: true))
        XCTAssertEqual(info.session, "session-new")
        XCTAssertEqual(methods().filter { $0.hasPrefix("session/") }, ["session/fork", "session/start"])
        let start = try XCTUnwrap(request("session/start"))
        XCTAssertEqual(start["approvalMode"] as? String, "allowAll")
        XCTAssertNil((start["config"] as? [String: Any])?["mcpServers"])
    }

    func testAnAsideStreamsOnlyItsAgentMessagesText() async throws {
        let text = AsideText()
        adapter = try asideAdapter(text)
        _ = try await adapter.open(SessionRequest(resume: "s-old", fork: true))
        let end = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "FAKE_SPEAK"))
        XCTAssertEqual(end.outcome, .completed)
        XCTAssertEqual(text.pieces, ["Hel", "lo", "world"],
                       "no reasoning, no other field, no other session; all before prompt returned")
        XCTAssertEqual(text.runs, ["Hello", "world"], "a second item a run of its own")
        XCTAssertEqual(text.unended, [], "every run ended before prompt returned")
        _ = try await adapter.prompt(Message(id: "m_2", agent: "mu", text: "FAKE_SPEAK"))
        XCTAssertEqual(text.runs, ["Hello", "world", "Hello", "world"])
        XCTAssertEqual(text.unended, [])
    }

    func testTheAsidesInstructionsLeadOnlyItsFirstTurnAndAreItsPrompt() async throws {
        adapter = try asideAdapter(AsideText())
        _ = try await adapter.open(SessionRequest(resume: "s-old", fork: true))
        _ = try await adapter.prompt(Message(id: "m_1", agent: "mu", text: "hello"))
        let first = try XCTUnwrap(request("turn/start")?["input"] as? [[String: Any]])
        XCTAssertEqual(first.first?["text"] as? String, Self.asideInstructions + "\n\n---\n\nhello")
        _ = try await adapter.prompt(Message(id: "m_2", agent: "mu", text: "again"))
        let second = try XCTUnwrap(request("turn/start")?["input"] as? [[String: Any]])
        XCTAssertEqual(second.first?["text"] as? String, "again")

        let argv = try XCTUnwrap(MuseFakeServe.arguments(in: root)?["argv"] as? [String])
        let config = argv[try XCTUnwrap(argv.firstIndex(of: "-c")) + 1]
        XCTAssertEqual(config, #"run.developer_prompt="Answer here, in your own words.""#)
    }

    func testAnAsideHostHasNoWayToSirius() async throws {
        adapter = try asideAdapter(AsideText())
        _ = try await adapter.open(SessionRequest(resume: "s-old", fork: true))
        let launched = try XCTUnwrap(MuseFakeServe.arguments(in: root))
        XCTAssertNil(launched["socket"] as? String, "not even one inherited")
        XCTAssertFalse((launched["path"] as? String)?.hasPrefix("/opt/sirius/Helpers:") == true)
        XCTAssertEqual(launched["noUpdate"] as? String, "1")
    }

    func testTheAsideEnvironmentDropsTheSocketAndHelpers() {
        let helpers = URL(fileURLWithPath: "/opt/sirius/Helpers")
        let base = ["PATH": "/usr/bin", "SIRIUS_SOCKET": "/tmp/inherited.sock", "HOME": "/Users/u"]
        let aside = MuseLaunch.environment(base, socketPath: "/s", helpers: helpers, aside: true)
        XCTAssertNil(aside["SIRIUS_SOCKET"])
        XCTAssertEqual(aside["PATH"], "/usr/bin")
        XCTAssertEqual(aside["HOME"], "/Users/u")
        XCTAssertEqual(aside["MUSE_NO_AUTO_UPDATE"], "1")
        let agent = MuseLaunch.environment(base, socketPath: "/s", helpers: helpers)
        XCTAssertEqual(agent["SIRIUS_SOCKET"], "/s")
        XCTAssertEqual(agent["PATH"], "/opt/sirius/Helpers:/usr/bin")
        XCTAssertEqual(MuseLaunch.environment(base, socketPath: "/s", helpers: helpers, aside: false), agent)
    }

    func testFindsMuseRegisteredThenOnPathThenInstalled() {
        let present: Set = ["/reg/muse", "/usr/bin/muse", "/Users/u/.local/bin/muse"]
        let isExecutable = { (path: String) in present.contains(path) }
        XCTAssertEqual(MuseLaunch.findExecutable(registered: "/reg/muse", environment: ["PATH": "/usr/bin"],
                                                 home: "/Users/u", isExecutable: isExecutable), "/reg/muse")
        XCTAssertEqual(MuseLaunch.findExecutable(registered: "", environment: ["PATH": "/bin:/usr/bin"],
                                                 home: "/Users/u", isExecutable: isExecutable), "/usr/bin/muse")
        XCTAssertEqual(MuseLaunch.findExecutable(registered: "", environment: [:],
                                                 home: "/Users/u", isExecutable: isExecutable),
                       "/Users/u/.local/bin/muse")
        XCTAssertNil(MuseLaunch.findExecutable(registered: "", environment: [:], home: "/nobody",
                                               isExecutable: isExecutable))
    }

    func testCommandIdsAreUUIDv7() {
        let id = MuseCommand.id(now: Date(timeIntervalSince1970: 1_793_915_677.852))
        XCTAssertTrue(id.hasPrefix("01a1adb4-"), id)
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.map(\.count), [8, 4, 4, 4, 12])
        XCTAssertEqual(parts[2].first, "7")
        XCTAssertTrue("89ab".contains(parts[3].first!))
        XCTAssertNotEqual(MuseCommand.id(), MuseCommand.id())
    }
}

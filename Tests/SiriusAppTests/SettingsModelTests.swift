import XCTest
import ParrotCore
import SiriusAdapters
import SiriusCore
import SiriusProtocol
@testable import SiriusApp

// The Settings window's model: the sidebar and the agents'
// list-then-focus, and that a change writes agent.json once, only when it
// differs, and reloads the host.
@MainActor
final class SettingsModelTests: XCTestCase {
    private var written: [AgentRegistration] = []
    private var reloads = 0

    private func registration(_ harness: AgentRegistration.Harness, fast: Bool? = nil) -> AgentRegistration {
        AgentRegistration(agent: AgentChoice.id(harness), name: AgentChoice.name(harness), harness: harness,
                          executable: "/bin/sh", root: "/tmp/work-\(harness.rawValue)", effort: "low", fast: fast)
    }

    private func model(existing: [AgentRegistration], fails: Bool = false) -> SettingsModel {
        let agents = AgentChoice.choices(existing: existing, detector: AgentDetector())
        for agent in agents { agent.simulateFound("/bin/sh") }
        return SettingsModel(agents: agents, shortcuts: ShortcutsModel(compose: .compose, holdKey: .fn),
                             dictation: ModelRegistry.shared[0],
                             write: { [unowned self] in
                                 if fails { throw CocoaError(.fileWriteNoPermission) }
                                 self.written.append($0)
                             },
                             onSave: { [unowned self] in self.reloads += 1 })
    }

    override func setUp() {
        written = []
        reloads = 0
    }

    func testSidebarOrderAndStart() {
        XCTAssertEqual(SettingsSection.allCases.map(\.title), ["General", "Permissions", "Agents", "Context", "Dictation"])
        XCTAssertEqual(model(existing: []).section, .general)
    }

    func testFocusThenBackReturnsToTheList() {
        let model = model(existing: [registration(.claudeCode)])
        model.focus(.claudeCode)
        XCTAssertEqual(model.section, .agents)
        XCTAssertEqual(model.focused, .claudeCode)
        XCTAssertTrue(model.back())
        XCTAssertNil(model.focused)
        XCTAssertFalse(model.back(), "on the list, Esc closes the window")
    }

    func testSelectingASectionLeavesTheFocusedAgent() {
        let model = model(existing: [registration(.codex)])
        model.focus(.codex)
        model.select(.general)
        model.select(.agents)
        XCTAssertNil(model.focused, "Agents opens on the list again")
    }

    func testAChangeWritesTheAgentAndReloads() throws {
        let model = model(existing: [registration(.codex)])
        let codex = try XCTUnwrap(model.agent(.codex))
        XCTAssertTrue(codex.fast, "Codex is fast by default")
        XCTAssertFalse(model.save(codex), "nothing changed")
        codex.fast = false
        XCTAssertTrue(model.save(codex))
        XCTAssertEqual(written.map(\.fast), [false], "off is written, since absent means on")
        XCTAssertEqual(written.first?.root, "/tmp/work-codex", "the workspace is kept")
        XCTAssertEqual(reloads, 1)
        XCTAssertFalse(model.save(codex), "unchanged since it was written")
        XCTAssertEqual(written.count, 1)
    }

    func testFastOffIsWrittenAsAbsent() throws {
        let model = model(existing: [registration(.claudeCode, fast: true)])
        let claude = try XCTUnwrap(model.agent(.claudeCode))
        XCTAssertTrue(claude.fast)
        claude.fast = false
        model.save(claude)
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.fast)
    }

    func testTurningAnAgentOffWritesFalseAndOnAgainWritesTrue() throws {
        let model = model(existing: [registration(.museCode)])
        let muse = try XCTUnwrap(model.agent(.museCode))
        XCTAssertTrue(muse.enabled, "absent means on")
        XCTAssertTrue(muse.isRunning)
        muse.enabled = false
        XCTAssertTrue(model.save(muse))
        XCTAssertFalse(muse.isRunning, "the list says Off")
        muse.enabled = true
        XCTAssertTrue(model.save(muse))
        XCTAssertEqual(written.map(\.enabled), [false, true], "once written, on stays written")
        XCTAssertEqual(written.map(\.root), ["/tmp/work-muse-code", "/tmp/work-muse-code"], "the workspace is kept")
        XCTAssertEqual(reloads, 2)
    }

    func testAnUnchangedAgentLeavesEnabledOut() throws {
        let model = model(existing: [registration(.codex)])
        let codex = try XCTUnwrap(model.agent(.codex))
        codex.effort = "high"
        model.save(codex)
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.enabled)
    }

    func testAnAgentWithoutAWorkspaceWritesNothing() throws {
        let model = model(existing: [])
        let claude = try XCTUnwrap(model.agent(.claudeCode))
        XCTAssertFalse(claude.isRegistered)
        claude.effort = "high"
        XCTAssertFalse(model.save(claude))
        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(reloads, 0)
    }

    func testAFailedWriteKeepsTheOldRegistration() throws {
        let model = model(existing: [registration(.codex)], fails: true)
        let codex = try XCTUnwrap(model.agent(.codex))
        codex.effort = "high"
        XCTAssertFalse(model.save(codex))
        XCTAssertEqual(codex.current?.effort, "low")
        XCTAssertEqual(reloads, 0)
    }

    func testDictationNote() throws {
        let base = try XCTUnwrap(ModelRegistry.find(DictationModel.defaultID))
        XCTAssertEqual(SettingsModel.dictationNote(base), "English only · \(base.sizeMB) MB · shared with Parrot")
    }
}

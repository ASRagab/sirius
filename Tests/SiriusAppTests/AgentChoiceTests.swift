import XCTest
import SiriusAdapters
import SiriusProtocol
@testable import SiriusApp

// A new registration starts Claude and Codex at effort low; an
// existing one keeps the effort it has.
@MainActor
final class AgentChoiceTests: XCTestCase {
    private func choice(_ harness: AgentRegistration.Harness, current: AgentRegistration? = nil) -> AgentChoice {
        let choice = AgentChoice(harness: harness, current: current, detector: AgentDetector())
        choice.simulateFound("/bin/sh")
        return choice
    }

    func testClaudeDefaultsToLowEffort() {
        XCTAssertEqual(AgentChoice.defaultEffort(.claudeCode), "low")
    }

    func testCodexDefaultsToLowEffort() {
        XCTAssertEqual(AgentChoice.defaultEffort(.codex), "low")
    }

    func testExistingRegistrationKeepsItsEffort() {
        let current = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                        executable: "/bin/sh", root: "/tmp/work", effort: "high")
        XCTAssertEqual(choice(.claudeCode, current: current).registration?.effort, "high")
    }

    // A new agent works in its harness's trusted folder with
    // nothing chosen.
    func testANewAgentTakesItsTrustedFolder() {
        let agent = AgentChoice(harness: .codex, current: nil, detector: AgentDetector(), trusted: "/Users/u/work")
        XCTAssertTrue(agent.usesTrusted, "trusted while the CLI is looked for")
        agent.simulateFound("/bin/sh")
        XCTAssertTrue(agent.usesTrusted)
        XCTAssertEqual(agent.registration?.root, "/Users/u/work")
        XCTAssertEqual(agent.registration?.harness, .codex)
    }

    func testAnExistingAgentKeepsItsFolderOverATrustedOne() {
        let current = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode,
                                        executable: "/bin/sh", root: "/Users/u/mine")
        let agent = AgentChoice(harness: .claudeCode, current: current, detector: AgentDetector(),
                                trusted: "/Users/u/other")
        agent.simulateFound("/bin/sh")
        XCTAssertFalse(agent.usesTrusted)
        XCTAssertEqual(agent.registration?.root, "/Users/u/mine")
    }

    func testWithoutTheCLIOrATrustedFolderNothingIsUsed() {
        let missing = AgentChoice(harness: .codex, current: nil, detector: AgentDetector(), trusted: "/Users/u/work")
        missing.simulateMissing()
        XCTAssertFalse(missing.usesTrusted)
        XCTAssertNil(missing.registration)
        XCTAssertNil(choice(.claudeCode).registration, "no folder, no registration")
    }
}

// What the Settings window shows of an agent and writes for it.
@MainActor
final class AgentChoiceSettingsTests: XCTestCase {
    private func registered(_ harness: AgentRegistration.Harness, model: String? = nil, effort: String? = "low",
                            root: String = "/Users/u/notes") -> AgentChoice {
        let current = AgentRegistration(agent: AgentChoice.id(harness), name: AgentChoice.name(harness),
                                        harness: harness, executable: "/bin/sh", root: root,
                                        model: model, effort: effort)
        let choice = AgentChoice(harness: harness, current: current, detector: AgentDetector())
        choice.simulateFound("/bin/sh")
        return choice
    }

    func testSummaryNamesWorkspaceModelAndEffort() {
        XCTAssertEqual(registered(.claudeCode).settingsSummary, "notes · Default model · Low effort")
        XCTAssertEqual(registered(.claudeCode, model: "claude-opus-5-5", effort: "xhigh").settingsSummary,
                       "notes · claude-opus-5-5 · Extra high effort")
        XCTAssertEqual(registered(.codex, effort: nil).settingsSummary, "notes · Default model · Default effort")
    }

    func testSummaryWithoutWorkspaceOrCLI() {
        let new = AgentChoice(harness: .codex, current: nil, detector: AgentDetector())
        new.simulateFound("/bin/sh")
        XCTAssertEqual(new.settingsSummary, "No workspace yet")
        let missing = AgentChoice(harness: .codex, current: nil, detector: AgentDetector())
        missing.simulateMissing()
        XCTAssertEqual(missing.settingsSummary, "Not installed")
    }

    func testEffortOptionsPerHarnessKeepAHandWrittenOne() {
        XCTAssertEqual(registered(.claudeCode).effortOptions, [nil, "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(registered(.codex).effortOptions, [nil, "minimal", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(registered(.codex, effort: "turbo").effortOptions.last, "turbo")
    }

    func testModelOptionsAreDefaultAndTheRegisteredOne() {
        XCTAssertEqual(registered(.claudeCode).modelOptions, [nil])
        XCTAssertEqual(registered(.claudeCode, model: "claude-opus-5-5").modelOptions, [nil, "claude-opus-5-5"])
    }

    func testRegistrationCarriesTheEditsAndKeepsTheRest() {
        let current = AgentRegistration(agent: "claude", name: "Claude", harness: .claudeCode, executable: "/bin/sh",
                                        root: "/Users/u/w", voice: "Samantha", effort: "low",
                                        consolidateAfterIdle: 30)
        let choice = AgentChoice(harness: .claudeCode, current: current, detector: AgentDetector())
        choice.simulateFound("/bin/sh")
        XCTAssertEqual(choice.registration, current, "nothing changed, nothing to write")
        choice.model = "claude-opus-5-5"
        choice.effort = "max"
        choice.fast = true
        let written = choice.registration
        XCTAssertEqual(written?.model, "claude-opus-5-5")
        XCTAssertEqual(written?.effort, "max")
        XCTAssertEqual(written?.fast, true)
        XCTAssertEqual(written?.voice, "Samantha")
        XCTAssertEqual(written?.consolidateAfterIdle, 30)
    }

    func testWorkspaceNameIsCutInTheMiddle() {
        XCTAssertEqual(registered(.codex, root: "/Users/u/sirius").workspaceName, "sirius")
        XCTAssertEqual(registered(.codex, root: "/Users/u/a-very-long-workspace-name").workspaceName,
                       "a-very-lon…pace-name")
    }

    func testSavedMakesItRegistered() throws {
        let new = AgentChoice(harness: .codex, current: nil, detector: AgentDetector())
        XCTAssertFalse(new.isRegistered)
        new.saved(AgentRegistration(agent: "codex", name: "Codex", harness: .codex, executable: "/bin/sh", root: "/w"))
        XCTAssertTrue(new.isRegistered)
    }

    // A new Codex agent is registered with fast: true; one whose
    // agent.json leaves fast out stays so until it is turned off.
    func testCodexFastModeIsWrittenOnlyWhereItMatters() {
        let new = AgentChoice(harness: .codex, current: nil, detector: AgentDetector(), trusted: "/w")
        new.simulateFound("/bin/sh")
        XCTAssertTrue(new.fast)
        XCTAssertEqual(new.registration?.fast, true)
        let existing = registered(.codex)
        XCTAssertTrue(existing.fast)
        XCTAssertNil(existing.registration?.fast, "left out, as it was")
        existing.fast = false
        XCTAssertEqual(existing.registration?.fast, false)
        let claude = AgentChoice(harness: .claudeCode, current: nil, detector: AgentDetector(), trusted: "/w")
        claude.simulateFound("/bin/sh")
        XCTAssertFalse(claude.fast)
        XCTAssertNil(claude.registration?.fast, "Claude stays as it was")
    }

    func testComposeTextFollowsTheRecording() {
        let shortcuts = ShortcutsModel(compose: .compose, holdKey: .fn)
        XCTAssertEqual(shortcuts.composeText, KeyComboText.string(.compose))
        shortcuts.simulate(.recording(hint: nil))
        XCTAssertEqual(shortcuts.composeText, "Press new shortcut…")
        shortcuts.simulate(.refused("Taken by macOS"))
        XCTAssertEqual(shortcuts.composeText, "Taken by macOS")
    }
}

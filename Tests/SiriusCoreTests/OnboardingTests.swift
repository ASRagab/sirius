import XCTest
@testable import SiriusCore

final class OnboardingTests: XCTestCase {
    func testShowsUntilCompletedAndWheneverNoAgentIsRegistered() {
        XCTAssertTrue(Onboarding.showsWindow(hasAgents: false, completed: false))
        XCTAssertTrue(Onboarding.showsWindow(hasAgents: false, completed: true))
        XCTAssertTrue(Onboarding.showsWindow(hasAgents: true, completed: false))
        XCTAssertFalse(Onboarding.showsWindow(hasAgents: true, completed: true))
    }

    func testGetStartedWaitsForBothGrantsAndAnAgent() {
        let none = GrantState(accessibility: false, microphone: .notDetermined)
        let microphoneOnly = GrantState(accessibility: false, microphone: .granted)
        let accessibilityOnly = GrantState(accessibility: true, microphone: .denied)
        let both = GrantState(accessibility: true, microphone: .granted)
        for grants in [none, microphoneOnly, accessibilityOnly] {
            XCTAssertFalse(Onboarding.canGetStarted(grants: grants, agentsChosen: 2))
        }
        XCTAssertFalse(Onboarding.canGetStarted(grants: both, agentsChosen: 0))
        XCTAssertTrue(Onboarding.canGetStarted(grants: both, agentsChosen: 1))
    }

    func testFromSettingsOnlyAnAgentIsNeeded() {
        let none = GrantState(accessibility: false, microphone: .notDetermined)
        XCTAssertTrue(Onboarding.canGetStarted(grants: none, agentsChosen: 1, requiresGrants: false))
        XCTAssertFalse(Onboarding.canGetStarted(grants: none, agentsChosen: 0, requiresGrants: false))
    }

    func testTheFoldersLineCountsTrustedWorkspaces() {
        XCTAssertEqual(Onboarding.foldersLine(count: 2), "2 trusted workspaces")
        XCTAssertEqual(Onboarding.foldersLine(count: 1), "1 trusted workspace")
        XCTAssertNil(Onboarding.foldersLine(count: 0))
    }

    func testWithoutTrustedFoldersTheLineAsksOrCounts() {
        XCTAssertEqual(Onboarding.chosenFoldersLine(count: 0), "Choose a workspace")
        XCTAssertEqual(Onboarding.chosenFoldersLine(count: 1), "1 workspace")
        XCTAssertEqual(Onboarding.chosenFoldersLine(count: 2), "2 workspaces")
    }
}

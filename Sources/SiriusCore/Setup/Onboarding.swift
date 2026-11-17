import Foundation

// The first-run onboarding's rules, with no AppKit: the app's
// OnboardingWindow is the view. One sheet, after Parrot's (parrot
// Sources/ParrotApp/UI/OnboardingWindow.swift): the keys, the
// two grants, and the agents' folders, then Get Started.
public enum Onboarding {
    // UserDefaults' key for the window having been through: set by Get
    // Started or closing the window by hand, as Parrot's
    // `onboarding.completed`.
    public static let completedKey = "onboarding.completed"

    // Whether the window opens at launch: until it has been through once,
    // and whenever no agent is registered, since Sirius does nothing
    // without one. An install from before the onboarding sees it once.
    public static func showsWindow(hasAgents: Bool, completed: Bool) -> Bool {
        !hasAgents || !completed
    }

    // Whether Get Started takes a click: an agent with its folder, and, the
    // first time through, both grants, since fn does nothing without them.
    // Opened again from Settings…, the grants no longer hold it.
    public static func canGetStarted(grants: GrantState, agentsChosen: Int, requiresGrants: Bool = true) -> Bool {
        agentsChosen > 0 && (!requiresGrants || grants.allGranted)
    }

    // The folders line: how many trusted folders the agents
    // will work in, called workspaces, kept short so it is no
    // wider than the rows above it, e.g. "2 trusted workspaces".
    // The tooltip names each agent's folder. Nil when none is used.
    public static func foldersLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) trusted \(count == 1 ? "workspace" : "workspaces")" // TODO(copy): copy
    }

    // The folders line once a folder has been chosen by hand, and before
    // any is, when no trusted folder was found.
    public static func chosenFoldersLine(count: Int) -> String {
        guard count > 0 else { return "Choose a workspace" } // TODO(copy): copy
        return "\(count) \(count == 1 ? "workspace" : "workspaces")" // TODO(copy): copy
    }
}

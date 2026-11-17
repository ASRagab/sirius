import Foundation

// Sirius's own settings in UserDefaults keep snake_case keys, as agent.json
// does. The keys first written in camelCase are moved once, at launch, so a
// choice made before the rename survives it; only the new key is written.
public enum SettingsKeys {
    // The composer's last chosen agent (ComposerController).
    public static let lastAgent = "composer.last_agent"
    // Whether the composer reads what the app in front has open and
    // selected (AmbientContext). Unset is on.
    public static let ambientContext = "composer.ambient_context"

    public static func ambientContextEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: ambientContext) == nil ? true : defaults.bool(forKey: ambientContext)
    }

    // Old key, new key.
    public static let renamed: [(old: String, new: String)] = [
        ("shortcut.holdToTalk", Shortcuts.holdKey),
        ("composer.lastAgent", lastAgent),
    ]

    // Moves each old key's value to its new key and removes the old one. A
    // value already under the new key wins, so it never goes back.
    public static func migrate(_ defaults: UserDefaults) {
        for (old, new) in renamed {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: old)
        }
    }
}

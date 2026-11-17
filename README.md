<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="Sirius">
</p>

# Sirius

Talk to your agents from anywhere on your Mac. Hold `fn` and say what you want, or press ⌘⇧J to type it, and Claude Code or ChatGPT / Codex gets to work in its own folder. When it has something to tell you, the reply comes back as a small toast, a notification or a spoken line, so you can keep doing what you were doing.

## 1. Install

Download [Sirius](https://trysirius.app/download), drag Sirius to Applications, and open it. It lives in the menu bar.

Requires macOS 14+ on Apple Silicon. Sirius is signed and notarized, so the permissions you grant survive updates.

## 2. First run

Setup is one sheet.

- **Shortcuts.** Hold `fn` to talk and ⌘⇧J to compose; click either to change it.
- **Permissions.** Allow the microphone, so Sirius can hear you while you hold `fn`, and Accessibility, so it can see the key and paste text. Each has its own Allow button; nothing is asked for unannounced. If Parrot is running, quit it so `fn` isn't handled twice.
- **Workspaces.** Sirius looks for `claude` and `codex` on your PATH, and for the copy of Codex inside ChatGPT.app. Each agent works in the folder its own CLI most recently used among those you already trust (Claude Code's trusted projects, Codex's trusted projects), and the sheet says so in one line. Change opens the list of agents; click one to pick another workspace. If neither has a trusted folder, the line's Choose opens the same list.

Get Started is enabled once both permissions are allowed and an agent has a workspace. Then hold `fn` and say, "Hello, what can you do?", or press ⌘⇧J to type instead.

Sirius needs Claude Code 2.1.71 or later and Codex 0.132.0 or later. If yours is older, a toast tells you to update it.

## 3. Usage

- **Hold `fn` and speak** to send what you said to an agent. Start with its name ("Claude, …" or "Codex, …") to pick one; otherwise it goes to the agent last chosen in the composer.
- **Hold ⌃ and `fn`** to paste what you said at the cursor instead, in any app.
- **Press ⌘⇧J** to open the composer. The current agent shows beside the send button, and ⌘/ switches to the next one. With the composer open, `fn` dictates into it, so you can edit before sending.

Speech recognition runs on your Mac. The first start downloads the speech model (about 145 MB); if you already use Parrot, Sirius reuses its model and your dictionary at `~/.config/parrot/dictionary`.

Both shortcuts can be changed in **Settings…** from the menu-bar icon. The compose shortcut can be any key with ⌘, ⌃ or ⌥, or an F-key. The hold key can be `fn`, right ⌥, right ⌘ or ⌃; with ⌃ as the hold key, ⌃⇧ pastes at the cursor.

The first time an agent sends a notification, macOS asks whether Sirius may show them.

## 4. Updates

Sirius updates itself. It checks once a day, tells you when a new version is ready, and installs it when you click. **Check for Updates…** in the menu checks now.

## 5. Build from source

```sh
swift build && swift test
scripts/dev-install.sh      # build, sign, and install Sirius.app
```

`scripts/build-app.sh` builds `build/Sirius.app` on its own. Both sign with the Developer ID in your keychain if there is one; without one the app is ad-hoc signed, and macOS forgets its permissions on every rebuild. The design is in [docs/architecture.md](docs/architecture.md).

## 6. License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## 7. Reporting bugs

Open an issue at [github.com/humanitas-labs/sirius/issues](https://github.com/humanitas-labs/sirius/issues) and attach `~/Library/Logs/Sirius/sirius.log`. The log records what Sirius did, not what you said.

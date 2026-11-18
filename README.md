<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/icon-light.png">
    <img src="docs/assets/icon.png" width="128" alt="Sirius">
  </picture>
</p>

# Sirius

Talk to your agents from anywhere on your Mac. Hold `fn` and speak, or press ⌘⇧J to type, and your agent gets to work in its own folder. Replies come back as a toast, a notification or a spoken line.

Sirius is bring your own harness (BYOH): it has no model of its own and drives the agent CLI you already use, with your account and settings. Claude Code, ChatGPT / Codex and Muse Code work out of the box; others are one adapter away ([docs/byoh.md](docs/byoh.md)).

## 1. Install

Download [Sirius](https://trysirius.app/download), drag it to Applications, and open it. It lives in the menu bar. Setup is one sheet: allow the microphone and Accessibility, and confirm each agent's workspace (the folder its CLI most recently used among those you trust). If Parrot is running, quit it so `fn` isn't handled twice.

Requires macOS 14+ on Apple Silicon, and Claude Code 2.1.71+, Codex 0.132.0+ or Muse Code 1.4.14+. Sirius is signed and notarized, and it updates itself: **Check for Updates…** in the menu checks now.

## 2. Usage

| Shortcut | What it does |
|---|---|
| Hold `fn` and speak | Send to an agent. Start with its name ("Claude, …") to pick one |
| Hold ⌃ and `fn` | Paste what you said at the cursor, in any app |
| ⌘⇧J | Open the composer; `fn` dictates into it |
| ⌘/ (in the composer) | Switch to the next agent |

Change both shortcuts in **Settings…**. Speech recognition runs on your Mac; the first start downloads the speech model (about 145 MB), or reuses Parrot's model and dictionary. The full manual ships in the app under **Sirius Manual**, and your agent can answer questions from it ([source](packaging/agent/manual/index.md)).

## 3. How it works

Each agent is a CLI session Sirius keeps warm in its workspace through a per-harness adapter. The agent reaches you by calling Sirius (the `sirius` command or the `sirius-mcp` server), never by its own output. See [docs/architecture.md](docs/architecture.md) and [docs/byoh.md](docs/byoh.md).

## 4. Build from source

```sh
swift build && swift test
scripts/dev-install.sh      # build, sign, and install Sirius.app
```

Without a Developer ID in your keychain the app is ad-hoc signed, and macOS forgets its permissions on every rebuild.

## 5. License and bugs

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Report bugs at [github.com/humanitas-labs/sirius/issues](https://github.com/humanitas-labs/sirius/issues) with `~/Library/Logs/Sirius/sirius.log` attached; it records what Sirius did, not what you said.

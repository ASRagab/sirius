# Asides

Last updated: `2026.11.09`. This is the as-built map of the feature. The short version in context is [architecture.md](architecture.md) §4.1.

> An aside is a side conversation with an agent in a window of its own. It runs on a fork of the agent's session, so it starts knowing everything the agent knew, and what it says and does streams into the window as one stream of events, the same shape for every harness. The main session never sees it, apart from one note when it closes.

## Contents

1. [The whole picture](#1-the-whole-picture)
2. [The pieces](#2-the-pieces)
3. [Opening from the composer](#3-opening-from-the-composer)
4. [Opening from the agent](#4-opening-from-the-agent)
5. [One turn](#5-one-turn)
6. [Closing](#6-closing)
7. [How each harness forks and streams](#7-how-each-harness-forks-and-streams)
8. [Rules the code holds](#8-rules-the-code-holds)
9. [Files on disk](#9-files-on-disk)
10. [Not verified, not built](#10-not-verified-not-built)

---

## 1. The whole picture

```
                          ┌──────────────────────── Sirius.app ────────────────────────┐
                          │                                                            │
  ⌘Return in composer ───►│  AsideController ──────────► AsideWindow                   │
                          │   (one per app)               page · field                 │
  agent: display aside ──►│        │  ▲                      ▲     │                   │
   (socket, AppCommandQueue)       │  │ events               │     │ typed reply       │
                          │        ▼  │ (TurnEvent, turn ended)    ▼                   │
                          │   AgentHost.openAside / sendAside / closeAside             │
                          │        │                                   │               │
                          │        ▼                                   ▼ on close      │
                          │   AsideSession (actor) ──┐        asides/<id>.md           │
                          │    own queue of turns    │        + note on the agent's    │
                          │        │                 │ onEvent  AgentTurnQueue         │
                          │        ▼                 │                                 │
                          │   Adapter built with AsideOptions                          │
                          └────────│───────────────────────────────────────────────────┘
                                   ▼
                     second harness process (claude / codex app-server / muse serve)
                     on a FORK of the agent's session; no socket, no sirius tools
```

Two things sit side by side for one agent while an aside is open:

- **The main session**: the agent's usual adapter and `AgentTurnQueue`. Nothing about it changes. It replies through toasts as always.
- **The aside**: a second adapter of the same harness, in a second process, on a copy of the session. Its plain text is the reply.

They share only the registration (root, model, executable) and the starting history. Neither waits for the other.

## 2. The pieces

| Piece | File | What it does |
|---|---|---|
| `AsideSession` | `Sources/SiriusCore/AsideSession.swift` | One aside. An actor that owns the aside's adapter, queues turns, and publishes `events`: `.event(TurnEvent)` and `.turnEnded(failure:)`. Keeps the transcript: a turn's answer is its runs of text joined by a blank line, with commentary left out. |
| `AsidePrompts` | same file | The aside's instructions, the first-turn wording when the agent opened it, and the note the main session gets on close. |
| `AsideOptions` | `Sources/SiriusCore/Adapter.swift` | What turns an ordinary adapter into an aside's: `instructions` and an `onEvent` callback. |
| `TurnEvent` | same file | What an aside's turn says and does, one shape for all three harnesses: steps, runs of text (`textStarted`, `textDelta`, `textEnded`, each with an id and a phase of answer or commentary), reasoning, tool calls and their updates, and notices such as a retry. |
| `SessionRequest.fork` | same file | Asks `open` for a copy of the session, not the session. |
| Adapter changes | `Sources/SiriusAdapters/ClaudeAdapter.swift`, `CodexAdapter.swift`, `Muse/MuseAdapter.swift` and their stream parsers | Fork the session, hand the turn to `onEvent`, and withhold every route back to Sirius. |
| Event mappers | `Sources/SiriusAdapters/Claude/ClaudeEvents.swift`, `Codex/CodexEvents.swift`, `Muse/MuseEvents.swift`, `ToolLine.swift` | One per harness: turns the harness's own stream into `TurnEvent`s, and closes whatever is still open when a turn ends or is cut off. `ToolLine` writes a tool call's one-line title. |
| `AgentHost` | `Sources/SiriusAdapters/AgentHost.swift` | `openAside`, `sendAside`, `closeAside`. Builds the aside's adapter from the agent's registration, copies attachments, files the transcript, leaves the note. |
| Notes | `Sources/SiriusCore/AgentTurnQueue.swift`, `MessageRenderer.swift` | `note(_:)` holds a line from Sirius until the user's next message to the agent, then renders it after the message as `[Sirius: …]`. |
| `AsideController` | `Sources/SiriusApp/Aside/AsideController.swift` | The app's one owner of open asides. Opens the window, reads `events` into it, forwards typed replies, closes. |
| `AsideWindow` | `Sources/SiriusApp/Aside/AsideWindow.swift` | The window, dark like the composer: the page (a read-only text view) and a single-line pill to answer in, with the +, the agent's mark and the send button. Escape or ⌘W closes it. Files and images attach by paste, drop or the +. |
| `AsideTranscript` | `Sources/SiriusApp/Aside/AsideTranscript.swift` | What the page shows: the user's words in a bubble at the right with any images above it, the agent's answers as plain text, commentary dimmed, the runs under way, one activity line under them, and replies waiting. |
| `AsideMarkdown` | `Sources/SiriusApp/Aside/AsideMarkdown.swift` | Markdown to attributed text. All the styling lives here. |
| `AsideSnapshots` | `Sources/SiriusApp/Aside/AsideSnapshots.swift` | `Sirius --aside-snapshots <dir>` renders the window in seven states to PNG, with no agent. |
| Protocol | `Sources/SiriusProtocol/Validation.swift`, `docs/protocol/proto.ts` | `display` kind `aside` with one text block, the brief, up to 2,000 characters. |

The layering follows the rest of the app: `SiriusCore` knows what an aside is but nothing about harnesses or windows, `SiriusAdapters` knows how each harness forks, and `SiriusApp` knows how it looks.

## 3. Opening from the composer

1. `ComposerTextView.keyDown` sees ⌘Return and calls `onSendAside`. Plain Return still calls `onSend`.
2. `ComposerController.sendAside` takes the text, the attachments and the selected agent, calls `onAside`, and closes the composer without handing focus back to the previous app, since the aside's window is about to take it.
3. `main.swift` wires `onAside` to `AsideController.openAside(agent:, .user(text:attachments:))`.
4. The controller calls `AgentHost.openAside`, which reads the agent's current session id from `state.json`, creates the `AsideSession` and starts warming its harness.
5. The controller builds the `AsideWindow`, shows the user's words on the page with "Thinking…" under them, and sends the text as the first turn through `AgentHost.sendAside`.

The window is on screen before the fork has started. If the aside cannot open (unknown agent, or six already open), the user gets an alert toast.

## 4. Opening from the agent

1. During a turn in the main session the agent sends `display` with kind `aside` and a brief, as its bundled instructions tell it to in place of the ack toast.
2. The request arrives on the agent's socket, passes validation, and reaches `AppCommandQueue.accept`, which calls the `openAside` closure `main.swift` set.
3. That calls `AsideController.openAside(agent:, .agent(brief:))`. Steps 4 and 5 above follow, with two differences: the page shows only "Thinking…", and the first turn is `AsidePrompts.opened(brief:)`, a bracketed note telling the fork to answer the user's last message in full.
4. The agent gets `{"delivered": true}` once the window is up, and ends its main turn.

The fork is taken while the main turn is still inside that tool call. The fork therefore sees an unfinished tool call at the end of its history; the aside instructions tell it to ignore that.

### Beside what the user had selected

When the app in front answers the Ambient Context Protocol, an aside opens beside the passage the user was pointing at, by either door.

- **From the composer.** `ComposerController` reads the app behind it again as ⌘Return is pressed and passes that answer, or what the app answered when the composer opened if the reread fails or takes longer than 0.3 s. `AsideController` takes the first focused item the app can locate and asks the app where it is.
- **From the agent.** Every element the user was pointing at in a message's `<context>` (each selected one, and the innermost in focus) carries `anchor="…"`, a handle from `AmbientAnchors` (`Sources/SiriusCore/AmbientContext.swift`). The agent hands it back: `sirius display aside --anchor <anchor> "<brief>"`, or `anchor` on the `display` tool. `AsideController` resolves it to the app, process, run and item it was given for, and asks that app where the item is.

The handle is Sirius's, not the app's id: two apps may both call an item `sel-1`, and an id means nothing after the app restarts. Handles are random, the latest 256 are kept, and none survive a restart of Sirius.

An anchor never fails the display. A handle Sirius does not know, an app that has quit or restarted, an item gone or scrolled out of view, a slow answer, or no room beside the item: the aside opens in its usual place and the log says which. `AmbientPlacement` chooses the frame; `asides` logs ids and outcomes, never content.

## 5. One turn

1. `AgentHost.sendAside` copies any attachments into the agent's `attachments/` and calls `AsideSession.send`, which queues the turn and returns.
2. The session's pump takes turns one at a time. Before the first it calls `adapter.open(SessionRequest(resume: <agent's session>, fork: true))`.
3. `adapter.prompt` delivers the turn. The message is rendered by `MessageRenderer.renderAside`: the user's words alone, with no `<sirius message>` wrapper and no reply note.
4. As the harness streams, the adapter's mapper turns each line into `TurnEvent`s and the adapter calls `onEvent` with each on its reader thread. `AsideSession` built that callback: it records text runs in a lock-protected buffer and yields `.event(event)` on `events`.
5. `AsideController` reads `events` on the main actor and calls `AsideWindow.hear`. The window keeps events in the order heard and does not show a piece of text the moment it is heard: a harness sends 150 words in about a second and a half after a wait of seconds, which read as the whole answer landing at once. It holds what it has heard and, 30 times a second, moves 12% of what is waiting onto the page, never fewer than 6 characters, re-rendering only the runs under way and following the bottom if the user was already there. An event that is not text (a run ending, a tool call, a notice) is applied once the text heard before it has been shown.
6. A turn can hold several runs of text. A run that has ended settles into the page when the next begins, a paragraph apart. Commentary, what the agent says about its work before the answer, is shown dimmed. Under the text sits one activity line: a notice if there is one, else the running tool call ("Searching AgentTurnQueue…"), else "Thinking…" whenever the turn is running and nothing is being written.
7. When `prompt` returns, the session records the answer in its transcript and yields `.turnEnded`. The window settles the answer into the page once all of it has been shown, and only then sends a reply that was waiting.

A reply can carry files: pasted, dropped on the window or chosen with the +, they show as tiles in the field until sent, then on the page (images as pictures, other files by name), and reach the agent as attachments the same way the composer's do.

A reply typed while a turn runs is not sent at once. `AsideTranscript` holds it, shows it dimmed under the answer, and the controller sends it when `.turnEnded` arrives. This keeps the page in the order things were said.

If the harness dies mid-turn, the turn ends with a failure line on the page, and the next turn reopens the aside's own session (not a new fork), so the conversation so far is kept.

## 6. Closing

1. Escape, ⌘W or the close button closes the window. Its `windowWillClose` calls the controller, which cancels its event reader and calls `AgentHost.closeAside`.
2. `AsideSession.close` drops queued turns and stops the harness. A turn cut off keeps what it had said.
3. If the agent said anything, the host writes the transcript to `agents/<agent>/asides/<id>.md`.
4. The host calls `note(_:)` on the agent's main `AgentTurnQueue` with `AsidePrompts.closedNote`: what the aside was about, how many exchanges, and the transcript's path.
5. The note is saved in `state.json` and rides the user's next message to that agent, after the message, as `[Sirius: …]`. It is dropped once a turn carrying it completes. A peer's `dm` message never carries it.

Quitting Sirius closes every aside the same way (`AgentHost.stopAll`).

## 7. How each harness forks and streams

| | Fork | Stream | Kept from Sirius |
|---|---|---|---|
| Claude Code | `--resume <session> --fork-session` | `--include-partial-messages`; each `stream_event` content block is a run of text, reasoning or a tool call, and the tool call stays open until its `tool_result`. No phase: every run is answer. Subagent lines are left out. | no `SIRIUS_SOCKET`, no helpers on `PATH`, no `--allowedTools Bash(sirius:*)`, unnamed session |
| Codex | `thread/fork {threadId, excludeTurns}`; falls back to an ephemeral fork, then to a new thread | `item/started`, the `item/*/delta` methods and `item/completed` of the aside's own thread; `agentMessage` items carry their phase from the start, so commentary is marked as it streams | no `sirius` MCP server, no `SIRIUS_SOCKET` |
| Muse Code | `session/fork {sessionId}`, then `session/setApprovalMode allowAll` | `item/started`, `item/delta`, `item/updated`, `item/completed`; an `agentMessage` names its phase only when it ends, so a commentary run dims then | no MCP config, no socket or helpers |

Instructions differ by harness because of what a fork inherits. Claude takes the aside instructions as its system prompt. A Codex fork keeps the parent thread's developer instructions, so the aside instructions lead the first turn's input instead. Muse gets them both ways.

## 8. Rules the code holds

- **The main session's output is still never shown.** Only an adapter built with `AsideOptions` hands anything on.
- **An aside cannot reach the user through Sirius.** No socket, no helpers, no MCP server. Its words are the reply.
- **An aside keeps the agent's other tools.** It can read, search, run commands and edit files in the agent's root.
- **All of a turn's events arrive before the turn's end.** Adapters call `onEvent` synchronously and in order before `prompt` returns; the session and window rely on it.
- **Whatever starts, ends.** Every run of text or reasoning gets its end event and every tool call a final status, even when the turn is interrupted or the harness dies; a tool call left running is closed as failed.
- **The window shows tool calls as one line, never their output.** Arguments and results stay in the harness.
- **Nothing said in an aside enters the main session.** The only trace is the closing note, and only if the agent spoke.
- **At most six asides are open at once** (`AsideController.limit`). A seventh from an agent is refused with `QUEUE_FULL`.

## 9. Files on disk

| Path | Contents |
|---|---|
| `~/Library/Application Support/Sirius/agents/<agent>/asides/<id>.md` | The transcript of a closed aside, as `## User` and `## Agent` sections |
| `~/Library/Application Support/Sirius/agents/<agent>/state.json` | Gains `notes`: lines waiting for the agent's next turn |
| The harness's own session store | The fork's session, left in place after close |

## 10. Not verified, not built

- **Codex** non-ephemeral fork with `excludeTurns` has not been run live; the adapter falls back to an ephemeral fork if it is refused.
- **Time to first text** on a long real session is unmeasured. On a two-turn Claude session it was 2.4 s.
- **The user's own `instructions.md`** is not applied in an aside; the aside instructions replace the agent's.
- **Agents already registered** may not have the "send an aside" line in their seeded instructions, so they may never open one themselves.
- **Tables** are shown as typed, in the code face.
- **Event mappings written from the schema alone**, with no recording behind them: reasoning on Codex and Muse, retry notices on all three, Codex patches and web searches. The recorded cases (text, a shell tool call, an interrupt, per harness) are frozen in `Tests/SiriusAdaptersTests/Fixtures/`.
- **The new stream has not been run live in the window.** It has been run live below the window: `AsideLiveTests` (gated by `SIRIUS_LIVE_ASIDE`) forks a real session on each harness, from a second process, and checks a turn with a shell tool call; all three passed on 2026.11.09.
- **Deferred by decision:** an aside that follows its passage as the user scrolls, anchors that outlive a restart of Sirius, Sirius routing a message to an aside by its own judgment, and dictation into an aside.

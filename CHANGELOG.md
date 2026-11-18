# Changelog

What changed in each version of Sirius. Before 1.0, a version that removes something or changes what an agent relies on bumps the minor number; everything else is a patch. Only the newest version is offered as a download and an update.

## 0.4.4 · 2026.11.18

* **Apps can say their context is sensitive.** An app that marks what it shares as sensitive gets the same warning as Mail and Chrome (Ambient Context Protocol 0.2.4). Chrome's provider now marks itself.
* **Models by name.** The Model menu in Settings lists each agent's main models by name: Fable 5.2, Opus 5.5, Sonnet 5.5 and Haiku 5.5 for Claude; GPT-6.2 Astra, GPT-6.1 Sol and others for Codex. An id typed into the agent's file still shows.
* **Paste at cursor, your way.** Choose the modifier you hold with the talk key to paste at the cursor: ⌃ by default, or ⇧, ⌥ or ⌘.
* **Settings → Context, simplified.** Two lists, "Apps that share natively" and "Onscreen", as plain rows with a quiet "Sensitive" beside the switch. "Use ambient context" and the warning switch sit together at the top.
* **Agents in order.** Claude, Codex, Cursor, Gemini, then Muse.
* **Menu.** Open manual, Check for Updates… and Quit Sirius together at the bottom.

## 0.4.3 · 2026.11.18

* **Two more agents.** Cursor's CLI and Google's Antigravity CLI (Gemini) join Claude Code, Codex and Muse Code. Say "Cursor, …" or "Gemini, …" to reach them. They take one message at a time.

## 0.4.2 · 2026.11.18

* **Onscreen context.** In Preview, Notes, Safari and Finder, Sirius reads what is open and selected itself, through the Accessibility permission. A note is named by its title, folder and date; a Finder window by its full path. Mail is there too, off until you turn it on. Messages is never read. Your agent is told when context was read this way.
* **The line follows you.** It quotes how your selection begins, and updates as you select something else, while the composer is open.
* **A warning for sensitive apps.** Before a message carries context from Mail or Chrome, Sirius asks once more: the send button turns white, Return sends, Cancel goes back, and "Don't warn again" stops it for that app. Spoken messages get the same warning in the composer.
* **Settings.** A General page with Keys and Toasts, and a Context page with every app that gives context and a switch for each. The window resizes.
* **Fixed.** The context line no longer lags in Notes.

## 0.4.1 · 2026.11.18

* **A manual.** "Open manual" in the menu opens it as a PDF. Every agent is told where it is, so you can ask yours how Sirius works.
* **Toast duration.** Choose how long toasts stay, in Settings; 3 seconds by default.
* **Working memory** is now a set of instructions agents follow, with no separate tool.

## 0.4.0 · 2026.11.17

* **Asides are gone.** The side-conversation window and the agent's ability to open one are removed. Long answers come back as a toast that stays, or a notification.

## 0.3.1 · 2026.11.17

* **The context line.** One quiet line at the bottom of the composer says what goes with your message: the app's icon, what is open, and what is selected. It follows the app while the composer is open. Click × or press ⌘⌫ at the start of the text to send without it.
* **Fixed.**
  * An agent's settings for consolidation now reach it.
  * A stalled agent no longer stops Sirius reading its replies.
  * Reloads no longer overlap, and an agent moved to another folder never starts on its old session.
  * Attachments are copied whole or not at all.
  * A message resent after a restart says its context was not kept.
  * The composer remembers the agent you last chose.

## 0.3.0 · 2026.11.16

The first version in this repository's history. Asides, context from the app in front (Ambient Context Protocol 0.2), onboarding in one sheet, the Settings window, faster replies, and working memory.

## 0.2.0 · 2026.10.14

Earlier history is not kept here.

---

Requires macOS 14 or later on Apple Silicon, with at least one of: Claude Code 2.1.71+, Codex 0.132.0+, Cursor's CLI, Google's Antigravity CLI, or Muse Code 1.4.14+.

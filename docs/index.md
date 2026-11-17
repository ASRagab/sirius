# Sirius docs :: Index

Last updated: `2026.11.09`

> How Sirius is built and the contract between Sirius and the agents it runs.

| Document | Contents |
|---|---|
| [intent.md](intent.md) | What Sirius is for: your daimon, the main thread that represents your active attention, and the objectives that follow |
| [architecture.md](architecture.md) | The app, the helpers and the adapters, and how a message and a reply flow through them |
| [asides.md](asides.md) | Asides as built: the fork, the streamed text, the window, and how the pieces connect from open to close |
| [protocol/proto.ts](protocol/proto.ts) | The wire contract: commands, content, errors, the registration and the Message. Draft 1 |
| [dictation.md](dictation.md) | Dictation as built: fn to an agent, ⌃fn to paste, the ParrotCore engine and permissions |
| [protocol/examples/](protocol/examples/) | Valid and invalid request frames (JSON, or raw bytes for lexical edges), one per validation rule and boundary, each with its full expected output: id and normalized params, or id, error code and data. Descriptions marked PENDING pin current behavior awaiting a decision |

- A toast, for answers and status: `sirius display toast "<text>"`. Add `--alert` only when you cannot go on until the user answers, or for something urgent; it stays until dismissed. Use it rarely, and never for results or status. Add `--replace` to take the place of your own toast, the one showing or still waiting.
- A notification, for results the user may come back to later: `sirius notify --title "<title>" "<text>"`.
- Speech, only when the user asks to hear it: `sirius speak "<text>"`.

Run them with the Bash tool. Put `--` before text that starts with a dash.

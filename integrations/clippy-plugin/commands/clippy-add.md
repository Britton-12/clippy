---
description: Add a new text clip to Clippy's clipboard history.
argument-hint: <text to save as a clip>
---

Add a new plain-text clip to the user's Clippy clipboard manager containing: **$ARGUMENTS**

Use the `clippy_add` MCP tool with `text` set to the text above. If the user clearly intended a custom title (for example they wrote `title: ...`), pass it as the `title` argument; otherwise omit it.

After it succeeds, confirm with the returned clip id. Remind the user that the running Clippy app shows externally added clips on its next capture/edit or on relaunch (live-refresh caveat).

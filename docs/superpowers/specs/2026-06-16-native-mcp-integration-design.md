# Native MCP + App Intents Integration — Design

Date: 2026-06-16
Status: Approved (brainstorming), pending spec review
Branch: `feature/native-mcp-integration`

## Problem

The existing MCP integration is a bundled Node.js HTTP+SSE server that the Swift app
launches as a subprocess, reached by clients through the `mcp-remote` NPX bridge. It
fails in three compounding ways:

1. **Backwards port check.** `McpServerController.isPortFree()`
   (`Sources/Clippy/Integrations/McpServerController.swift:116-139`) calls `bind()`
   with `SO_REUSEADDR` to "test" availability, leaving a phantom socket in the kernel
   and producing false "port in use" readings. The UI surfaces this directly
   (`SettingsView.swift:903-987`).
2. **Too many fragile hops.** client -> `npx`/`mcp-remote` -> HTTP -> SSE -> Node ->
   SQLite. Every hop is a place to hang. This is the source of the repeated ~4-minute
   timeouts in Claude Desktop.
3. **Node + TCP-port dependency** for what should be a local, in-process capability.

Reconnaissance of Paste.app confirms the fix: Paste's strongest feature is its MCP
server, built **natively in Swift** (SwiftNIO + the official MCP Swift SDK) with a tiny
bundled `paste-mcp-stdio` shim that clients spawn directly. Paste's weakness is its thin
tool surface (~4 intents), not its transport. So "abandon MCP" and "make it an
extension/plugin" converge: a Claude Desktop Extension *is* a packaged MCP server. The
right move is replacing the Node/port/bridge architecture, not dropping MCP.

## Goals

- Kill the port-binding bug, the `mcp-remote` hop, and the Node dependency.
- A reliable local integration that responds in well under 2 seconds, never 4 minutes.
- Feature parity: **if a user can do it in clippy, the integration can do it too** —
  clips, categories, paste-to-frontmost, Scripts, and AI Actions.
- A second native surface — App Intents — so clippy works in Shortcuts, Siri, and
  Spotlight with no AI client involved.
- A settings panel that shows what is running, where it lives, and lets the user force a
  reset when stuck.

## Non-goals (YAGNI)

- No AppleScript `.sdef`, no Services-menu entry, no Share/Action app extension in this
  pass. (Candidates for a later pass; not required for the parity goal.)
- No OAuth on the local socket (Paste uses OAuth on an HTTP listener; a Unix-domain
  socket scoped to the user's container does not need it).
- No remote/network access. Local machine only.

## Architecture

### Removed

- `integrations/clippy-mcp/` (Node/TypeScript server) and its esbuild `index.mjs` bundle.
- `McpServerController` subprocess launching, health-poll loop, and `isPortFree()`.
- The `mcp-remote`-based install path and the port text field in Settings.

### Added

**`ClippyMCP` — native Swift MCP server, in-process.** Runs inside the running clippy
app, registered with all tools, backed by clippy's existing Swift service layer (the same
services the UI calls). Live capabilities (run-script, run-AI-action, paste-to-frontmost)
become direct function calls instead of an IPC round-trip to a separate process.

**Transport — Unix domain socket, no TCP port:**

- The in-app server listens on a Unix domain socket at a fixed path in clippy's container
  (e.g. `<App Data>/clippy-mcp.sock`). A socket file, not a port. "Port in use" no longer
  exists as a failure mode.
- A bundled **`clippy-mcp` helper binary** (in `Clippy.app/Contents/MacOS/`) is what AI
  clients spawn. It does exactly one thing: splice `stdin <-> socket <-> stdout`. Zero
  dependencies, instant spawn, nothing to hang on. All MCP protocol work happens in the
  app; the helper is a dumb byte pipe.
- Client config is just `command: /Applications/Clippy.app/Contents/MacOS/clippy-mcp`.
  No npx, no Node, no port, no SSE.
- If clippy is not running when a client connects, the helper launches it
  (`open -b <bundleid>`), waits for the socket, then connects, so it "just works."

```
AI client (Claude/Cursor/...)
   | spawns (stdio)
clippy-mcp  (bundled helper: stdin <-> UDS <-> stdout, ~dumb pipe)
   | Unix domain socket  (clippy-mcp.sock — a file, no port)
Clippy.app  (ClippyMCP server -> shared Swift service layer -> SQLite + live app actions)
```

### Open implementation question (verify before building)

Confirm against the official MCP Swift SDK docs (not from memory) that its stdio transport
accepts the socket's read/write `FileHandle`s directly. If the transport API does not
expose that, fall back to framing JSON-RPC over the socket ourselves (newline-delimited
JSON either way). Resolve via Context7 / the SDK's own docs at implementation time.

## Tool surface — one service layer, two front-ends

Both front-ends call the **same underlying Swift services**; no duplicated logic (DRY).

### MCP tools

- Clips: `search`, `list_recent`, `get`, `add`, `edit`, `delete`, `pin`
- Categories: `list_categories`, `create_category`, `rename_category`, `delete_category`,
  `set_category`
- Live: `paste_to_frontmost`, `list_scripts`, `run_script`, `list_ai_actions`,
  `run_ai_action`

### App Intents (Shortcuts / Siri / Spotlight)

Curated action subset, each with spoken phrases via `AppShortcutsProvider`
("Add to clippy", "Paste latest from clippy"):

- Add Clip, Get Latest Clip, Get Clip at Index, Search Clips, Paste Clip to Frontmost,
  Run Script on Clip, Run AI Action on Clip, Create Pinboard, Pin/Unpin Clip.

Full ID-based CRUD stays MCP-only — it is programmatic, not something said to Siri.

## Settings UI

Replaces the MCP tab. The reveal-in-Finder buttons are kept as requested; the
"kill process on port" request is reinterpreted to its real purpose — force-reset when
stuck — since there is no port process to kill.

```
 Integration  (MCP + Shortcuts)

 ( ●) Enable clippy integration

 Status    ● Listening            socket: clippy-mcp.sock   [ Reveal ⌕ ]
 Helper    clippy-mcp             /Applications/Clippy.app/…/MacOS/   [ Reveal ⌕ ]
 Clients   Claude Desktop · Cursor   (2 connected)

 Connect an AI client
   [ Claude Desktop ✓ ]  [ Claude Code ]  [ Cursor ]  [ VS Code ]   [ Copy config ]

 [ Restart listener ]   [ Clear stale socket ]
```

- **Reveal ⌕** in two places: reveals the live socket file, and reveals the bundled
  `clippy-mcp` helper in Finder (so the user can see what process clients spawn and where).
- **Restart listener** tears down and rebinds the UDS server. **Clear stale socket**
  unlinks an orphaned `.sock` file left by a crash. Together these replace "kill process
  on port".
- **Clients** row shows which AI clients are connected right now (a live diagnostic the
  old UI lacked).
- The port text field is gone.

## Install / connect flow

Each "Connect" button writes that client's MCP config to point `command` at the bundled
helper:

- Claude Desktop: `claude_desktop_config.json`
- Claude Code: `claude mcp add`
- Cursor: `cursor://` deep link
- VS Code: `mcp.json`

A ✓ shows when already installed. "Copy config" yields a ready JSON snippet for anything
else. No `mcp-remote`, no Node prerequisite, so install cannot half-succeed waiting on
`npx`.

## Migration

- Delete the `integrations/clippy-mcp` Node tree and its build step.
- Remove `McpServerController` subprocess/port code.
- Migrate any saved port setting to "enabled"; otherwise drop it.

## Testing + verification

- **Unit:** the shared service layer (CRUD, categories, scripts, AI actions) — both
  front-ends depend on it.
- **Stdio round-trip (regression guard):** spawn `clippy-mcp`, send `initialize` +
  `tools/list` + one tool call, assert a response in <2s. This is the direct guard
  against the old 4-minute timeout.
- **App Intents smoke test** via Shortcuts.
- **Real end-to-end:** connect Claude Desktop, run `clippy_list_categories`, capture
  evidence of the response.

## Risks

- MCP Swift SDK transport flexibility (see open question). Mitigation: self-framed
  JSON-RPC fallback over the socket.
- Bundling a second Mach-O executable (`clippy-mcp`) requires it to be signed and
  notarized with the app. Mitigation: add it to the existing signing/notarization step in
  the release pipeline.
- App-not-running auto-launch latency on first connect. Mitigation: helper waits on the
  socket with a bounded timeout and a clear error if the app fails to come up.

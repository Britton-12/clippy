# Clippy - agent notes

Project-specific conventions, gotchas, and decisions. Shared across Claude / Codex / Copilot.

## AI assistant (Sources/Clippy/AI/)

- The AI chat UI is `AIAssistantPanelView.swift`. It streams from a local LLM via
  **Ollama at `127.0.0.1:11434`** (providers in `AIProviders.swift` / `AIProvider.swift`,
  agent loop in `AIAgent.swift`). Tokens are appended to `@Published messages[i].text`
  (`AIAgent.swift:116`), so the message list re-renders on every token.
- Streaming bubble renders plain `Text` while live and swaps to `Markdown` (MarkdownUI)
  only when the turn ends (`isLive == false`). This avoids re-parsing markdown per token.

### GOTCHA: do not enable text selection on the live streaming bubble

`.textSelection(.enabled)` on the rapidly-mutating live `Text` installs SwiftUI's internal
`SelectionOverlay`, which re-runs AppKit text layout on every token. That layout invalidation
re-enters the SwiftUI AttributeGraph transaction and never converges -> main thread pinned at
~100% CPU on one core, memory grows unbounded (observed 1.6-2.1 GB), UI frozen, force-quit
required. `clippy.log` shows nothing because the loop never returns to the run loop.

Fix in place (working tree, see `AIAssistantPanelView.swift`): selection is gated off while
`isLive` via `View.textSelectionEnabled(_:)`, which returns `self` (no overlay) when disabled.
Selection returns the instant the turn finishes. Keep it this way; re-adding `.textSelection`
to the live branch reintroduces the freeze.

Evidence: `docs/evidence/` (two macOS `cpu_resource.diag` spindumps with the
`SelectionOverlay.updateNSView` heaviest stack, the tonight unified-log capture, and the
runtime CPU/RSS measurements of the fixed build). Verdict record: `docs/.run/findings.json`.

## Build / run

- SwiftPM project (`Package.swift`), no `.xcodeproj`. `swift build -c release` -> `.build/release/Clippy`.
- A packaged bundle lives at `build/Clippy.app`. To run a freshly built binary as a real app:
  copy the bundle to a non-iCloud path (iCloud regenerates Finder metadata that blocks codesign),
  stage the new binary into `Contents/MacOS/Clippy`, `xattr -cr`, then `codesign --force --deep --sign -`.
- Installed app is `/Applications/Clippy.app` (bundle id `com.jerry.clippy`).

## Debugging hangs on this machine

- CPU/memory runaways: read `/Library/Logs/DiagnosticReports/Clippy_*.cpu_resource.diag`
  ("Heaviest stack for the target process:" + Footprint). Readable without sudo (user is in
  `_analyticsusers`); sudo is denied by policy.
- `log` is shadowed by a shell function; call `/usr/bin/log` by absolute path. Run `log show`
  via the plain shell (not the context-mode sandbox, which redirects it) to a temp file.

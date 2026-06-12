# Changelog

## 2026-06-12 - Enterprise polish wave (branch feature/enterprise-polish)

### Fixed
- Status bar and Settings-header logo no longer renders with the top cut off. The lazy
  NSImage drawing handler ignored the destination rect, so on Retina backing stores the
  artwork filled only part of the buffer. Regression test renders the icon at 2x and
  asserts ink coverage in the top rows (StatusBarIconTests).
- Custom AI action set to "Copy to Clipboard" no longer silently overwrites the source
  clip; each output disposition now maps to its own proposal kind with regression tests.
- 1Password: copying a concealed field with no stored value is no longer a silent no-op
  (button disabled with an explanatory tooltip).
- Settings window is resizable (min 780x580); stale "Planned" MCP badge and leftover
  scaffolding captions removed.

### Added
- Scripts in the main panel: new "Scripts" sidebar section listing all saved scripts with
  run, live status, stdout/stderr/exit/duration output, copy output, and save-output-as-clip.
  Settings management screen unchanged.
- OCR for image clips: "Extract Text" context-menu action (Apple Vision, accurate mode,
  automatic language detection). Recognized text is copied to the clipboard and saved as a
  new clip labeled "Clippy OCR"; success/empty/failure surfaced via a status banner.
- 1Password deep field access: full item detail (sections in vault order, custom labels,
  multiple concealed fields, usernames, URLs), per-field reveal toggle and copy, TOTP
  fetched on demand, concealed-type pasteboard marker on every secret copy, optional
  clipboard auto-clear (default on, 90s, changeCount-guarded), op resolved via PATH.
- AI actions engine: user-definable actions (name, icon, prompt template with {clip} and
  {instruction}, temperature, max tokens, output disposition), seeded editable built-ins,
  managed in Settings > AI; AI submenu on text clips runs any action with diff-style
  approval where applicable.
- AI Assistant pane: chat surface in the sidebar driving an agentic tool-use loop
  (OpenAI, Anthropic, Ollama, Azure) with tools: search_clips, create_clip, list_scripts,
  run_script, execute_code. Script and code execution are default-OFF in Settings and
  always require per-call user confirmation showing exactly what will run. Code runs as
  the current user with a 30s timeout (no sandbox; the UI says so honestly).
- Settings > AI: Agent & Tools section (script/code execution toggles) and bundled MCP
  server setup block (integrations/clippy-mcp) for external agent access to clips.

### Changed
- Whole-app UI polish pass (40-finding audit executed and independently verified):
  theme tokens replace hardcoded colors in OnePassword/Scripts/AI surfaces, consistent
  typography, keyboard shortcut disclosure (Cmd+E, Cmd+Delete), accessibility labels,
  consistent empty states.

### Tests
- Suite grew from 0 to 190 tests (icon rendering, OCR, 1Password parsing incl.
  adversarial fixtures, AI engine: template substitution, tool gating, loop termination,
  disposition mapping, registry filtering).

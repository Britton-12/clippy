# Roadmap

Deferred / follow-up items, prioritized. Sourced from verifier reports and audit rows
not closed in the 2026-06-12 wave (details in .orchestrator/ evidence and findings).

## High value
- Streaming AI responses (provider protocol currently single-shot; assistant pane shows
  a working indicator instead of token streaming).
- AI vision: send image clips to multimodal providers (native Vision OCR shipped; AI-based
  extraction/description is the complement).
- Real sandbox for execute_code (sandbox-exec / restricted environment); today the control
  is per-call confirmation + 30s timeout, described honestly in the UI.
- Assistant conversation persistence across app restarts (in-memory per session today).

## Medium
- "Save as clip" for failed script runs with useful stdout (currently success-only).
- Semantic success/danger theme tokens, then migrate remaining systemGreen/systemRed
  usages in ScriptsPanelView and CategorySidePane.
- Deep-link "Manage Scripts..." to the exact Settings tab (opens Settings root today).
- 1Password: optional `op signin` / account switching; custom op binary path setting.
- Custom hotkey recording (binding currently fixed).

## Low
- error-path coverage for saveScriptOutput (bad-DB branch untested).
- MCP server lifecycle management in-app (start/stop/status of clippy-mcp).

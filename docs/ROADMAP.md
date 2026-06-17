# Roadmap

Deferred / follow-up items, prioritized. Sourced from verifier reports and audit rows
not closed in the 2026-06-12 wave (details in .orchestrator/ evidence and findings).

## High value
- On-device AI providers (deferred from the 2026-06-16 overhaul wave; the macOS 26
  floor they require is now in place):
  - Apple Intelligence via Foundation Models (`SystemLanguageModel` /
    `LanguageModelSession`): a new provider behind the existing
    `AIAgentProviderFactory`, gated on `SystemLanguageModel.default.availability`,
    mapped onto the current streaming + `AIToolDefinition` tool-calling interface.
  - MLX via `mlx-swift`: on-device inference provider with model selection /
    download / management; add `mlx-swift` to Package.swift after confirming its
    minimum platform. Extend `AIProviderKind` and the Settings AI tab for both.
- AppSettings/stores migration from `ObservableObject`/`@Published` to
  `@Observable` + `@State`/`@Bindable` (deferred; internal). CRITICAL ordering:
  rewire the Combine `$` projections (`ClipboardMonitor.$pollingIntervalMs`,
  `McpServerController.$mcpEnabled`/`$mcpPort`) to onChange/streams BEFORE removing
  `@Published`, and mark the `@Observable` classes `@MainActor`.
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

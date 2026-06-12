# Plan: Optional panel scaffold extraction in SettingsView (F6)

Source: PATHFINDER-2026-06-11 flowchart F6-archive-import-export.
Type: low-priority cleanup, no behavior change.
Execution gate: do this only when Sources/Clippy/UI/SettingsView.swift is already being edited for another reason.

## Scope

Consolidate duplicated panel scaffold logic in three handlers inside Sources/Clippy/UI/SettingsView.swift.

- exportTOML (currently around lines 559-571)
- importTOML (currently around lines 573-589)
- exportJSON (currently around lines 591-644)

Extract two private helpers.

- runSavePanel(name:types:_ body: (URL) throws -> String) -> String
- runOpenPanel(types:_ body: (URL) throws -> String) -> String

## Hard constraints

- Keep each handler's serialization path distinct.
- exportTOML keeps hand-written TOML export and file write.
- importTOML keeps TOML parse + upsert import path and skipped-image messaging.
- exportJSON keeps JSON encode shape and export message.
- Share only panel setup + runModal guard + do/catch result formatting.
- Do not touch sortOrder or junction one-liners (D8). Explicitly out of scope.
- If this file is not already being edited for another reason, skip this cleanup entirely.

## Phase 0: Pre-checks

1. Confirm SettingsView.swift is already modified in the current branch/worktree.

1. Capture current handler behavior text for regression checks.

- export success/failure message format
- import success with optional skipped-images suffix
- JSON export success/failure message format

1. Confirm no unrelated nearby edits are required.

## Phase 1: Add helper methods (private)

1. Add private func runSavePanel(name:types:_ body:) near the three handlers.

1. Helper responsibilities.

- create and configure NSSavePanel
- set allowedContentTypes and nameFieldStringValue
- guard panel.runModal() == .OK and panel.url is present
- if cancelled, return empty string sentinel (caller preserves existing UX by not updating result on cancel)
- execute body(url) in do/catch
- return body success string or Export failed: localized description

1. Add private func runOpenPanel(types:_ body:) with matching responsibilities for NSOpenPanel and import-oriented failure text (Import failed: ...).

Note:

- The helper can take an optional failurePrefix argument if needed to avoid hardcoding Export/Import wording incorrectly.
- Keep signatures requested by task unless compiler or clarity requires minimal additive parameter.

## Phase 2: Refactor handlers to keep only unique logic

1. exportTOML:

- Replace panel/guard/do/catch scaffold with runSavePanel call.
- Keep TOML export and write logic in closure body.
- Closure returns exact success string currently used.

1. importTOML:

- Replace scaffold with runOpenPanel call.
- Keep String(contentsOf:) + ClippyArchive.importTOML + skipped image suffix logic in closure body.
- Closure returns exact message currently used.

1. exportJSON:

- Replace scaffold with runSavePanel call.
- Keep ExportClip/ExportDocument payload generation + JSONEncoder config + write in closure body.
- Closure returns exact success string currently used.

1. Result assignment rules:

- Preserve current state targets (archiveResult for TOML export/import, exportResult for JSON export).
- Preserve cancel behavior (no user-facing failure message on cancel).

## Phase 3: Verification

Build checks:

1. Run dotnet build task is irrelevant here; use Swift project verification.

- swift build
- swift test

Behavior checks (end-to-end):

1. TOML export:

- Trigger export from Settings.
- Confirm file is written and success message is unchanged.

1. TOML import:

- Import a valid file with at least one missing image path.
- Confirm categories/clips import and skipped-images suffix appears when expected.

1. JSON export:

- Trigger export and confirm JSON shape and success message are unchanged.

1. Cancel checks:

- Cancel each panel and confirm no false failure message appears.

Diff hygiene:

1. Confirm only Sources/Clippy/UI/SettingsView.swift changed for this cleanup.

1. Confirm D8 one-liners remain untouched.

## Done criteria

- Duplicate panel scaffold removed from all three handlers.
- Serialization logic remains separate and behavior-identical.
- Build and tests pass.
- Manual export/import checks pass.
- No unrelated refactors included.

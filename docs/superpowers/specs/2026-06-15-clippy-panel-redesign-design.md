# Clippy Panel Redesign - Design

Date: 2026-06-15
Branch: feature/panel-ux-overhaul
Status: Approved, pending implementation plan

## Problem

The Clippy popup panel has four related UX defects and gaps:

1. **The whole window drags.** Clicking anywhere in the panel moves the window. Root cause: `PanelController.swift:158` sets `panel.isMovableByWindowBackground = true`. AppKit claims the mouse-down-drag from any background point before SwiftUI can see it.
2. **Reorganization drag-and-drop never fires.** The `.draggable`/`.dropDestination` code for filing clips into categories, reordering clips inside a category, and reordering categories already exists (`ReorderableForEach.swift`, `CategorySidePane.swift`, `ClipListView.swift`), but the window-background drag (defect 1) intercepts every drag, so none of it works. Fixing defect 1 unblocks all of it.
3. **No multi-select.** Selection is a single integer index (`ClipListView.swift:20 selectedIndex`). You cannot select several clips to paste in sequence, move/remove/delete as a batch, or set titles with AI across a batch.
4. **Branding and consistency drift.** No panel header carries the app identity; chrome (settings gear) lives inside the search bar; some surfaces use hardcoded `NSColor.system*` values instead of theme tokens. The app does not read as one coherent product.

## Goals

- A real panel header that is the only window-drag region.
- Working reorganization: clip -> category, clip reorder within a category, category reorder.
- A category membership model that is single by default, additive when the user opts in.
- Multi-select with batch actions: paste sequentially, paste combined, move to category, remove from category, delete, set titles with AI.
- A consistent visual identity anchored on the paperclip mark + "Clippy" wordmark and one signature accent, with hardcoded colors removed.

## Non-Goals

- No paste-queue / pasteboard-stack interception (each subsequent system Cmd-V popping the next clip). Sequential paste is a delayed loop of discrete paste events at the current cursor.
- No driving of the target app's field navigation (Clippy cannot Tab between fields in another app).
- No rework of the storage schema beyond what single/multi membership requires (the `clip_category` join table already supports many-to-many).
- No new themes. Named presets (Dracula, Nord, GitHub Dark, etc.) stay as-is.

## Existing Architecture (grounding)

- **Panel window:** `PastePanel: NSPanel` (`Panel/PastePanel.swift`), shown by `PanelController` (`Panel/PanelController.swift`). Borderless, non-activating, `isMovableByWindowBackground = true` at line 158.
- **Root content:** `ClipListView` (`UI/ClipListView.swift`) - `VStack { searchBar; Divider; GeometryReader { mainPane | CategorySidePane }; Divider; footer }`. Search bar is currently the topmost element (lines 227-290) and holds the settings gear.
- **Clip rows:** `ClipCardView` (`UI/ClipCardView.swift`). **Category rows:** `CategorySidePane` (`UI/CategorySidePane.swift`).
- **Drag/drop:** `UI/ReorderableForEach.swift` (token format `reorder:<kind>:<id>`, `reorderDraggable`/`reorderDropDestination` modifiers), `CategoryReorderModifier` in `ClipListView.swift:664-695` (emits `clip:<id>` from History pane, `reorder:clip:<id>` from a category pane), drop handlers in `CategorySidePane.swift:119-154` and `ClipListView.swift:686-692`.
- **Data model:** `Clip` (`Storage/Clip.swift`, has `userTitle: String?`), `Category` (`Storage/Category.swift`), `ClipCategory` join table (many-to-many). `ClipStore` (`Storage/ClipStore.swift`) holds `membership: [Int64: Set<Int64>]` and methods `categoryIDs(for:)`, `addClip(id:toCategory:)`, `setClip(_:inCategory:_:)`, `moveCategory`, `moveClip`.
- **Selection:** single `@State selectedIndex` (`ClipListView.swift:20`), arrow-key nav (`moveSelection`), Return -> `pasteSelected` -> `onPrimary`/`onPaste`.
- **Paste:** `PasteService.paste(_:asPlainText:)` (`Paste/PasteService.swift:19-30`) writes the pasteboard then posts Cmd-V after a 0.12s delay. Wired via `PanelController.onPaste` set in `AppDelegate.swift:98-106` (hide panel + `restoreFocusToPreviousApp()` + paste).
- **Settings:** `GeneralSettingsTab` in `UI/SettingsView.swift:217-346`. Toggle pattern: key string (`AppSettings.swift` Keys, ~line 150), default registration (~525), init from defaults (~604), `@Published var ... { didSet { defaults.set(...) } }` (~375). Example: `hideOnClickAway`.
- **Mascot:** SF Symbol `paperclip`, template image, in `Support/StatusBarIcon.swift:3-14`, accent-tinted; bounce animation at lines 33-59; already shown in the Settings header (`SettingsView.swift:51-54`).
- **Theme:** `ThemeTokens` (12 colors) in `Support/ThemePreset.swift`; `PanelTypography` roles in `Support/Theme.swift`; resolved via `AppSettings.theme`.

## Design

### A. Window header + drag fix

- Set `isMovableByWindowBackground = false` (`PanelController.swift:158`).
- New `PanelHeaderView` (new file `UI/PanelHeaderView.swift`), inserted as the first child of `ClipListView`'s root VStack, above `searchBar`. ~30pt tall.
  - Left: accent-tinted paperclip mark (reuse `StatusBarIcon.image()` rendering, matching `SettingsView.swift:51-54`) + "Clippy" wordmark using `PanelTypography.title`.
  - Right: pin toggle (reflects `settings.panelPinned`), settings gear (moved out of the search bar), close button (`onClose`).
- New `WindowDragHandle: NSViewRepresentable` (in the same file) whose backing `NSView` overrides `mouseDownCanMoveWindow { true }`. It is the header's background. The buttons sit above it as normal SwiftUI controls and do not move the window. No other view in the panel returns true, so only the header drags the window.
- Search bar (`ClipListView.swift:227-290`) loses the gear; it becomes magnifier + text field only.

Result: window drags only from the header; reorganization drag-and-drop (already implemented) now works with no token changes.

### B. Single-vs-multiple category model

- New setting `allowMultipleCategories: Bool`, default `false`. Full `AppSettings` pattern (key + default + init + `@Published` didSet).
- General tab toggle "Allow a clip in multiple categories" with help text, placed in the History or Behavior section of `GeneralSettingsTab`.
- New `ClipStore.fileClip(id: Int64, intoCategory categoryID: Int64)`:
  - `allowMultipleCategories == true`: additive (current `addClip` behavior).
  - `allowMultipleCategories == false`: remove the clip from every other category, then add to `categoryID` (single membership).
- Every clip-filing path routes through `fileClip`: the two drop handlers in `CategorySidePane.swift` (`clip:` and `reorder:clip:` payloads) and the categories menu in `ClipListView.swift:428-463`.
- Categories menu: checkbox-style when multiple is on; radio-style (selecting one clears the rest) when off.

### C. Multi-select + batch actions

- Selection state: add `@State selectedClipIDs: Set<Int64>` to `ClipListView`. Keep `selectedIndex` as the keyboard anchor. `selectedClipIDs` empty or single == today's behavior.
  - Plain click: select one (replace set).
  - Cmd-click: toggle one in/out of the set.
  - Shift-click: select the range between the anchor and the clicked row.
  - Cmd-A: select all visible clips. Esc: clear `selectedClipIDs` if non-empty, else close the panel.
- Visual: selected rows get the accent highlight (`tokens.accent`); a count chip ("3 selected") appears in the footer when 2+ are selected.
- Batch actions surface as a context menu on a selected row and as a slim action bar shown above the footer when 2+ are selected:
  - **Paste Sequentially** -> `PasteService.pasteSequence(_ clips: [Clip], asPlainText:)`: loop discrete paste events in selection order with a small inter-paste delay (start at ~0.15s after the existing 0.12s settle).
  - **Paste Combined** -> `PasteService.pasteCombined(_ clips: [Clip], separator: String, asPlainText:)`: join `contentText` with `\n`, write once, single Cmd-V.
  - **Move to category** (submenu, respects single/multi via `fileClip`).
  - **Remove from category** (only when viewing a specific category; removes membership for that category).
  - **Delete** (confirmation dialog showing the count, then `store.delete` per clip).
  - **Set Titles with AI** (run the existing AI-title action per selected clip; reuse `runAIAction`/`handleAIProposal` path).
- New `PanelController.onPasteMany` callback, wired in `AppDelegate` parallel to `onPaste` (hide panel if `hideAfterPaste`, restore focus, then call the chosen `PasteService` sequence/combined method).
- Image clips are valid for paste-sequential (each its own paste) but excluded from paste-combined and AI-title (text-only); the menu disables those items when the selection has no text clips.

### D. Branding / consistency pass

- Identity anchor: the header from section A (paperclip mark + "Clippy" wordmark) plus one signature accent applied to selection, active state, links, and the mascot tint.
- Default accent: **Clippy Amber `#E0A23C`** (one-line default change; named themes unaffected; user can still pick any accent).
- New semantic tokens `success` and `danger` on `ThemeTokens` (`Support/ThemePreset.swift`), defined per preset. Replace hardcoded values:
  - `SettingsView.swift:179-184` tab icon colors -> token-driven.
  - `ScriptsPanelView.swift:222,226` status greens/reds -> `tokens.success` / `tokens.danger`.
- Consistency: align spacing, corner radii, and SF Symbol weights across the panel header, search bar, side pane, and settings so the surfaces match.

## Verification

Toolchain is Command Line Tools only (no Xcode.app), so `swift test` (XCTest) cannot run here; gate on:

- Clean `swift build`.
- Manual runtime checks against the deployed app:
  - Window drags only from the header; clicking/dragging a clip or category never moves the window.
  - Clip -> category drop files the clip; with multiple off it moves (leaves the old category); with multiple on it adds.
  - Clip reorder within a category and category reorder both work.
  - Cmd/Shift/plain click select correctly; Cmd-A and Esc behave as specified.
  - Paste Sequentially lands N clips in order; Paste Combined lands one joined paste.
  - Batch move / remove / delete / AI titles operate on the whole selection.
  - "Allow a clip in multiple categories" persists across relaunch and changes filing behavior.
  - Default accent reads as Clippy Amber; no off-theme hardcoded colors remain on the audited surfaces.

## Risks / Open Questions

- `mouseDownCanMoveWindow` interaction with the non-activating panel: verify the header drags and the rest does not in a real run (the dedicated drag-handle NSView is the deliberate, explicit mechanism rather than relying on default view behavior).
- Sequential paste timing into slow target apps may need a tunable delay; start conservative and adjust during manual testing.
- AI-title batch could be slow / rate-limited for large selections; run sequentially with per-clip progress and allow cancel.

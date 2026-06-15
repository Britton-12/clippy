# Clippy Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the window-drag bug (which also unblocks reorganization drag-and-drop), add a single-vs-multiple category model, add multi-select with batch actions, and apply a consistent Clippy brand identity - all on `feature/panel-ux-overhaul`.

**Architecture:** A new SwiftUI `PanelHeaderView` backed by a dedicated `WindowDragHandle` NSView becomes the only window-drag region (`isMovableByWindowBackground` goes off), which lets the existing `.draggable`/`.dropDestination` code finally fire. Category filing routes through a new `ClipStore.fileClip` that honors an `allowMultipleCategories` setting. `ClipListView` gains a `Set<Int64>` selection with batch actions that call new `PasteService` sequence/combined methods through a new `onPasteMany` callback. A branding pass adds `success`/`danger` theme tokens, removes hardcoded colors, and defaults the accent to Clippy Amber.

**Tech Stack:** Swift 6, SwiftUI + AppKit (NSPanel), GRDB, SwiftPM. macOS app. Build gate: `swift build`. No XCTest in this environment.

---

## Verification model (read first)

This repo's test target is XCTest and **does not compile without Xcode.app**, which is not installed here. Therefore:

- The compile gate for every task is: `swift build` -> expect `Build complete!`.
- The behavior gate is a **manual runtime check**: rebuild and relaunch the app, then perform the listed action and observe the result. Use the project's existing build/deploy path (the same one prior sessions used to deploy to `/Applications`; if a script exists under `scripts/` or the repo root, use it - otherwise `swift build -c release` and launch the built binary).
- Where a piece of pure logic deserves a unit test (marked **DEFERRED TEST** in the task), add the XCTest case to the existing test target but do not expect to run it here; note it for the next Xcode-equipped run.

Commit after each task. Keep commits small.

## File map

**Create:**
- `Sources/Clippy/UI/PanelHeaderView.swift` - panel header view + `WindowDragHandle` NSViewRepresentable.

**Modify:**
- `Sources/Clippy/Panel/PanelController.swift` - disable background drag; add `onPasteMany`.
- `Sources/Clippy/UI/ClipListView.swift` - mount header; remove gear from search bar; selection `Set`; click handlers; batch action UI; route filing through `fileClip`.
- `Sources/Clippy/UI/ClipCardView.swift` - selected-state highlight; click modifiers (cmd/shift).
- `Sources/Clippy/UI/CategorySidePane.swift` - route clip-filing drops through `fileClip`.
- `Sources/Clippy/Storage/ClipStore.swift` - add `fileClip(id:intoCategory:)`.
- `Sources/Clippy/Support/AppSettings.swift` - add `allowMultipleCategories`.
- `Sources/Clippy/UI/SettingsView.swift` - General toggle; token-driven tab icon colors.
- `Sources/Clippy/Paste/PasteService.swift` - `pasteSequence`, `pasteCombined`.
- `Sources/Clippy/AppDelegate.swift` - wire `onPasteMany`.
- `Sources/Clippy/Support/ThemePreset.swift` - `success`/`danger` tokens on every preset.
- `Sources/Clippy/Support/Theme.swift` - default accent -> Clippy Amber.
- `Sources/Clippy/UI/ScriptsPanelView.swift` - status colors via tokens.

---

## PHASE A - Window header + drag fix

### Task A1: Add the WindowDragHandle and PanelHeaderView

**Files:**
- Create: `Sources/Clippy/UI/PanelHeaderView.swift`

- [ ] **Step 1: Create the header file with the drag handle**

```swift
import SwiftUI
import AppKit

/// An AppKit view that lets the user drag the borderless panel by this region
/// only. With `isMovableByWindowBackground` off on the panel, AppKit moves the
/// window only from views that return true here, so this is the sole drag area.
private final class DragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The panel's title bar: paperclip mark + "Clippy" wordmark on the left,
/// pin / settings / close controls on the right. The whole strip is draggable
/// except for the buttons.
struct PanelHeaderView: View {
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    private var tokens: ThemeTokens { AppSettings.shared.theme }
    private let settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusBarIcon.image())
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(tokens.accent)
            Text("Clippy")
                .font(PanelTypography.title(settings))
                .foregroundStyle(tokens.textPrimary)
            Spacer(minLength: 0)
            headerButton(systemName: isPinned ? "pin.fill" : "pin",
                         help: isPinned ? "Unpin panel" : "Pin panel",
                         action: onTogglePin)
            headerButton(systemName: "gearshape",
                         help: "Settings", action: onOpenSettings)
            headerButton(systemName: "xmark",
                         help: "Close", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(WindowDragHandle())
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }

    private func headerButton(systemName: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
```

Note: `panelOpacity` is the same value the existing `searchBar` reads for `tokens.headerBar` (see `ClipListView.swift:227-290`). If the property is named differently in `AppSettings`, match the name used in the search bar background.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` (the view is unreferenced but must compile).

- [ ] **Step 3: Commit**

```bash
git add Sources/Clippy/UI/PanelHeaderView.swift
git commit -m "feat(panel): add PanelHeaderView and WindowDragHandle"
```

### Task A2: Disable background drag and mount the header

**Files:**
- Modify: `Sources/Clippy/Panel/PanelController.swift:158`
- Modify: `Sources/Clippy/UI/ClipListView.swift` (root VStack ~76-98; search bar ~227-290)

- [ ] **Step 1: Turn off window-background dragging**

In `PanelController.swift`, change line 158 from:

```swift
panel.isMovableByWindowBackground = true
```
to:
```swift
panel.isMovableByWindowBackground = false
```

- [ ] **Step 2: Insert the header as the first child of the root VStack**

In `ClipListView.swift`, the root body is `VStack(spacing: 0) { searchBar; Divider(); GeometryReader {...}; Divider(); footer }`. Add the header above `searchBar`:

```swift
VStack(spacing: 0) {
    PanelHeaderView(
        isPinned: settings.panelPinned,
        onTogglePin: { settings.panelPinned.toggle() },
        onOpenSettings: onOpenSettings,
        onClose: onClose
    )
    Divider()
    searchBar
    Divider()
    // ... existing GeometryReader, Divider, footer unchanged
}
```

`onOpenSettings` and `onClose` are already closures on `ClipListView` (set in `PanelController.swift:54-67`). `settings` is the existing `AppSettings.shared` reference in this view.

- [ ] **Step 3: Remove the gear button from the search bar**

In `searchBar` (`ClipListView.swift:227-290`), delete the trailing settings gear `Button` (the one calling `onOpenSettings` with a 12pt `gearshape`/`gear` system image). Leave the magnifier icon and the `TextField`. The gear now lives in the header.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Manual runtime check**

Rebuild/relaunch. Open the panel.
- Drag from the new header strip -> window moves. PASS.
- Drag from anywhere else (search bar, a clip row, the side pane) -> window does **not** move. PASS.
- Click the header gear -> Settings opens. Click pin -> pin state toggles. Click X -> panel closes.

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/Panel/PanelController.swift Sources/Clippy/UI/ClipListView.swift
git commit -m "feat(panel): header is sole drag region; disable background drag"
```

### Task A3: Verify reorganization drag-and-drop now fires

No code change - this task confirms Task A2 unblocked the existing drag code.

- [ ] **Step 1: Manual runtime check**

Rebuild/relaunch.
- Drag a clip from the History pane onto a category row -> the clip is filed into that category (category color dot appears on the card). PASS.
- Open a category, drag a clip above/below another -> order changes. PASS.
- Drag a category row above/below another -> categories reorder. PASS.

If any of these still fail, the cause is NOT the window drag - inspect the specific `.dropDestination` handler named in the design's "Existing Architecture" section before proceeding.

- [ ] **Step 2: No commit** (verification only). If a fix was needed, commit it with `fix(panel): ...`.

---

## PHASE B - Single-vs-multiple category model

### Task B1: Add the allowMultipleCategories setting

**Files:**
- Modify: `Sources/Clippy/Support/AppSettings.swift` (Keys ~150; defaults ~525; init ~604; published vars ~375)

- [ ] **Step 1: Add the key**

In the `Keys` enum (near line 150, beside `hideOnClickAway`):

```swift
static let allowMultipleCategories = "allowMultipleCategories"
```

- [ ] **Step 2: Register the default**

In the defaults dictionary (near line 525, beside `Keys.hideOnClickAway: false`):

```swift
Keys.allowMultipleCategories: false,
```

- [ ] **Step 3: Add the published property**

Beside the other `@Published` toggles (near line 375):

```swift
@Published var allowMultipleCategories: Bool {
    didSet { defaults.set(allowMultipleCategories, forKey: Keys.allowMultipleCategories) }
}
```

- [ ] **Step 4: Initialize from defaults**

In `init` (near line 604, beside `hideOnClickAway = defaults.bool(...)`):

```swift
allowMultipleCategories = defaults.bool(forKey: Keys.allowMultipleCategories)
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/Support/AppSettings.swift
git commit -m "feat(settings): add allowMultipleCategories (default off)"
```

### Task B2: Add the General settings toggle

**Files:**
- Modify: `Sources/Clippy/UI/SettingsView.swift` (`GeneralSettingsTab` ~217-346)

- [ ] **Step 1: Add the toggle**

In `GeneralSettingsTab`'s History section (the section near line 267), add after the existing toggles, matching the `hideOnClickAway` toggle style at lines 280-284:

```swift
Toggle("Allow a clip in multiple categories", isOn: $settings.allowMultipleCategories)
    .help("Off by default: filing a clip into a category removes it from any other category, so each clip lives in exactly one. On: a clip can belong to several categories at once.")
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Manual runtime check**

Relaunch, open Settings -> General. Toggle is present, flips, and the value persists after quitting and reopening Settings.

- [ ] **Step 4: Commit**

```bash
git add Sources/Clippy/UI/SettingsView.swift
git commit -m "feat(settings): General toggle for multiple categories"
```

### Task B3: Add ClipStore.fileClip and route all filing through it

**Files:**
- Modify: `Sources/Clippy/Storage/ClipStore.swift` (beside `addClip(id:toCategory:)` ~154-156, `categoryIDs(for:)` ~132-135)
- Modify: `Sources/Clippy/UI/CategorySidePane.swift` (drop handlers ~135-154)
- Modify: `Sources/Clippy/UI/ClipListView.swift` (categories menu ~428-463)

- [ ] **Step 1: Add fileClip to ClipStore**

After `addClip(id:toCategory:)`:

```swift
/// Files a clip into `categoryID`, honoring the single-vs-multiple setting.
/// When multiple categories are disallowed (default), the clip is first
/// removed from every other category so it lives in exactly one.
func fileClip(id clipID: Int64, intoCategory categoryID: Int64) {
    if !AppSettings.shared.allowMultipleCategories {
        for existing in categoryIDs(forClipID: clipID) where existing != categoryID {
            setClip(id: clipID, inCategory: existing, false)
        }
    }
    addClip(id: clipID, toCategory: categoryID)
}
```

Use whatever existing accessor returns a clip's category IDs by id. The explorer found `categoryIDs(for clip: Clip) -> Set<Int64>` (line 132) reading `membership[id]`. If there is no id-based variant, add one:

```swift
func categoryIDs(forClipID clipID: Int64) -> Set<Int64> {
    membership[clipID] ?? []
}
```

And confirm the remove call: the explorer found `setClip(_:inCategory:_:)` (line 149-152) as the add/remove toggle. Match its real signature (it may be `setClip(_ clip: Clip, inCategory:, _ member: Bool)` or id-based). If it is clip-based, fetch the clip or use the underlying `database`/membership removal the same way `setClip` does. The required behavior: remove membership rows for all categories except `categoryID`, then add `categoryID`.

**DEFERRED TEST:** add `ClipStoreTests.test_fileClip_singleMode_movesClip` and `test_fileClip_multiMode_addsMembership` to the XCTest target asserting membership before/after for both setting states.

- [ ] **Step 2: Route the History-pane and category-pane clip drops through fileClip**

In `CategorySidePane.swift` (~135-154), the drop handler currently calls `store.addClip(id: clipID, toCategory: categoryID)` in both the `clip:` and `reorder:clip:` branches. Replace both with:

```swift
store.fileClip(id: clipID, intoCategory: categoryID)
```

- [ ] **Step 3: Route the categories context menu through fileClip**

In `ClipListView.swift` `categoriesMenu(_:)` (~428-463), the menu toggles membership via `store.setClip(_:inCategory:_:)`. Change the "add to category" branch to `store.fileClip(...)`. For the menu's checkmark/radio display: when `settings.allowMultipleCategories` is false, render each row as a radio (selecting one calls `fileClip`, which clears the others); when true, keep the checkbox toggle behavior (tap an already-member row to remove it via the existing `setClip(... false)`).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Manual runtime check**

Relaunch. With "Allow a clip in multiple categories" OFF:
- Drag a clip into Category A, then drag the same clip into Category B -> the clip shows only B's dot (it left A). PASS.
- Open Category A -> the clip is gone; open Category B -> it's there. PASS.

Turn the setting ON:
- File the same clip into A and B -> the card shows both dots; it appears in both categories. PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/Storage/ClipStore.swift Sources/Clippy/UI/CategorySidePane.swift Sources/Clippy/UI/ClipListView.swift
git commit -m "feat(categories): single-membership filing with opt-in multiple"
```

---

## PHASE C - Multi-select + batch actions

### Task C1: Add selection state and click handlers

**Files:**
- Modify: `Sources/Clippy/UI/ClipListView.swift` (selection state ~20; card construction ~371-405)
- Modify: `Sources/Clippy/UI/ClipCardView.swift` (add `isSelected` + tap handling)

- [ ] **Step 1: Add the selection set and a resolver**

Near the existing `@State private var selectedIndex = 0` (line 20) add:

```swift
@State private var selectedClipIDs: Set<Int64> = []

/// The clips the batch actions operate on: the explicit multi-selection if any,
/// otherwise the single keyboard-anchored clip.
private var actionableClips: [Clip] {
    if selectedClipIDs.isEmpty {
        return selectedClip.map { [$0] } ?? []
    }
    return visibleClips.filter { clip in clip.id.map { selectedClipIDs.contains($0) } ?? false }
}
```

- [ ] **Step 2: Add a click handler that interprets modifiers**

Add to `ClipListView`:

```swift
private func handleRowClick(_ clip: Clip, at index: Int, modifiers: EventModifiers) {
    guard let id = clip.id else { return }
    if modifiers.contains(.command) {
        if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) }
        else { selectedClipIDs.insert(id) }
        selectedIndex = index
    } else if modifiers.contains(.shift) {
        let lo = min(selectedIndex, index), hi = max(selectedIndex, index)
        let rangeIDs = visibleClips[lo...hi].compactMap { $0.id }
        selectedClipIDs.formUnion(rangeIDs)
        selectedIndex = index
    } else {
        selectedClipIDs = []          // plain click clears multi-select
        selectedIndex = index
    }
}
```

- [ ] **Step 3: Pass selection into the card and route taps**

In the card construction (`card(for:at:)` ~371-405) pass `isSelected: clip.id.map { selectedClipIDs.contains($0) } ?? false` into `ClipCardView`, and wrap the card so a tap calls `handleRowClick`. SwiftUI exposes modifier keys via a simultaneous gesture:

```swift
.gesture(TapGesture().modifiers(.command).onEnded { handleRowClick(row.clip, at: row.index, modifiers: .command) })
.gesture(TapGesture().modifiers(.shift).onEnded { handleRowClick(row.clip, at: row.index, modifiers: .shift) })
.onTapGesture { handleRowClick(row.clip, at: row.index, modifiers: []) }
```

Keep the existing double-click / primary-action behavior (paste on activate) intact; the single-tap above only changes selection. If the card already has an `onTapGesture` that pastes, move the paste to a double tap (`.onTapGesture(count: 2)`) so single tap = select, double tap = paste.

- [ ] **Step 4: Add isSelected to ClipCardView**

In `ClipCardView.swift`, add `let isSelected: Bool` to the struct and render a selection highlight (accent border/fill) when true:

```swift
.overlay(
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(isSelected ? tokens.accent : Color.clear, lineWidth: 2)
)
.background(isSelected ? tokens.accent.opacity(0.12) : Color.clear)
```

Match `tokens` to however the card already accesses theme tokens.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Manual runtime check**

Relaunch. Plain-click selects one (highlighted). Cmd-click adds/removes others. Shift-click selects a contiguous range. Double-click still pastes.

- [ ] **Step 7: Commit**

```bash
git add Sources/Clippy/UI/ClipListView.swift Sources/Clippy/UI/ClipCardView.swift
git commit -m "feat(select): multi-select via plain/cmd/shift click"
```

### Task C2: Selection keyboard shortcuts and count chip

**Files:**
- Modify: `Sources/Clippy/UI/ClipListView.swift` (key handlers ~237-243; footer ~footer view)

- [ ] **Step 1: Add Cmd-A and Esc handling**

Beside the existing `.onKeyPress` handlers:

```swift
.onKeyPress(.init("a"), phases: .down) { press in
    guard press.modifiers.contains(.command) else { return .ignored }
    selectedClipIDs = Set(visibleClips.compactMap { $0.id })
    return .handled
}
.onKeyPress(.escape) { _ in
    if !selectedClipIDs.isEmpty { selectedClipIDs = []; return .handled }
    onClose(); return .handled
}
```

If the panel already handles Escape elsewhere (it routes through `PastePanel.cancelOperation`), guard against double-close: only consume Escape here when `selectedClipIDs` is non-empty, otherwise return `.ignored` so the existing close path runs.

- [ ] **Step 2: Add a selection count chip to the footer**

In the `footer` view, when `selectedClipIDs.count >= 2`, show:

```swift
if selectedClipIDs.count >= 2 {
    Text("\(selectedClipIDs.count) selected")
        .font(PanelTypography.micro(settings))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(tokens.accent.opacity(0.18), in: Capsule())
        .foregroundStyle(tokens.accent)
}
```

- [ ] **Step 3: Reset selection when the visible list changes**

Where `selectedIndex` is reset on `.onChange(of: store.clips)` and `.onChange(of: selection)`, also clear `selectedClipIDs = []` so stale ids don't linger across panes.

- [ ] **Step 4: Build + manual check + commit**

Run: `swift build` -> `Build complete!`
Relaunch: Cmd-A selects all visible; chip shows the count; Esc clears the multi-select first, then closes on a second press; switching categories clears selection.

```bash
git add Sources/Clippy/UI/ClipListView.swift
git commit -m "feat(select): Cmd-A, Esc-clears-first, count chip"
```

### Task C3: PasteService sequence and combined methods

**Files:**
- Modify: `Sources/Clippy/Paste/PasteService.swift`

- [ ] **Step 1: Add the two methods**

```swift
/// Pastes several clips one after another as discrete Cmd-V events, in order.
/// Each lands at the current cursor; Clippy cannot move the target's cursor
/// between events, so consecutive pastes concatenate where the caret is.
func pasteSequence(_ clips: [Clip], asPlainText: Bool) {
    guard !clips.isEmpty else { return }
    let step = 0.15
    for (i, clip) in clips.enumerated() {
        let delay = 0.12 + Double(i) * step
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if !self.settings.movePastedItemToTop { self.monitor.ignoreNextChange() }
            self.writeToPasteboard(clip, asPlainText: asPlainText)
            Self.sendPasteKeystroke()
        }
    }
}

/// Joins the text of several clips with `separator` and pastes once.
/// Image clips are skipped (text-only join).
func pasteCombined(_ clips: [Clip], separator: String = "\n", asPlainText: Bool) {
    let text = clips.filter { $0.contentKind == .text }
        .map { $0.contentText }
        .joined(separator: separator)
    guard !text.isEmpty else { return }
    if !settings.movePastedItemToTop { monitor.ignoreNextChange() }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        Self.sendPasteKeystroke()
    }
}
```

These reuse the existing private `writeToPasteboard`, `sendPasteKeystroke`, `monitor`, and `settings` already in `PasteService` (lines 8-85).

**DEFERRED TEST:** `PasteServiceTests.test_pasteCombined_joinsTextClipsWithNewline` asserting the joined string for a mixed text/image selection.

- [ ] **Step 2: Build + commit**

Run: `swift build` -> `Build complete!`

```bash
git add Sources/Clippy/Paste/PasteService.swift
git commit -m "feat(paste): pasteSequence and pasteCombined"
```

### Task C4: Wire onPasteMany through the panel and app delegate

**Files:**
- Modify: `Sources/Clippy/Panel/PanelController.swift` (callbacks alongside `onPaste`)
- Modify: `Sources/Clippy/AppDelegate.swift` (handler ~98-106)
- Modify: `Sources/Clippy/UI/ClipListView.swift` (call site + closure plumbing)

- [ ] **Step 1: Add the callback to PanelController**

Beside `var onPaste: ((Clip, Bool) -> Void)?` add:

```swift
/// Paste several clips. `combined == true` joins them into one paste;
/// false pastes them sequentially.
var onPasteMany: (([Clip], _ combined: Bool, _ asPlainText: Bool) -> Void)?
```

In `show()` where the root `ClipListView` is built (lines 54-67), pass a new closure:

```swift
onPasteMany: { [weak self] clips, combined, asPlainText in
    self?.onPasteMany?(clips, combined, asPlainText)
},
```

Add the matching `onPasteMany` parameter to `ClipListView`'s initializer (a stored `let onPasteMany: ([Clip], Bool, Bool) -> Void`).

- [ ] **Step 2: Implement the handler in AppDelegate**

Beside the `panelController.onPaste = { ... }` block (lines 98-106):

```swift
panelController.onPasteMany = { [weak self] clips, combined, asPlainText in
    guard let self else { return }
    let s = AppSettings.shared
    if s.hideAfterPaste && !s.panelPinned { self.panelController.hide() }
    self.panelController.restoreFocusToPreviousApp()
    if combined {
        self.pasteService.pasteCombined(clips, asPlainText: asPlainText)
    } else {
        self.pasteService.pasteSequence(clips, asPlainText: asPlainText)
    }
}
```

- [ ] **Step 3: Build + commit**

Run: `swift build` -> `Build complete!` (no UI calls it yet; Task C5 adds the triggers.)

```bash
git add Sources/Clippy/Panel/PanelController.swift Sources/Clippy/AppDelegate.swift Sources/Clippy/UI/ClipListView.swift
git commit -m "feat(paste): onPasteMany plumbing panel -> app delegate"
```

### Task C5: Batch action menu and action bar

**Files:**
- Modify: `Sources/Clippy/UI/ClipListView.swift` (context menu on cards; action bar above footer)

- [ ] **Step 1: Add a batch action bar shown when 2+ are selected**

Add a view, rendered just above the `footer` when `selectedClipIDs.count >= 2`:

```swift
private var batchActionBar: some View {
    HStack(spacing: 10) {
        batchButton("Paste Seq.", "list.number") {
            onPasteMany(actionableClips, false, settings.pastePlainTextByDefault)
        }
        batchButton("Paste Joined", "rectangle.compress.vertical") {
            onPasteMany(actionableClips, true, settings.pastePlainTextByDefault)
        }
        batchButton("Delete", "trash") { requestBatchDelete() }
        batchButton("AI Titles", "sparkles") { runBatchAITitles() }
        Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(tokens.footerBar.opacity(settings.panelOpacity))
}

private func batchButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(label, systemImage: symbol).font(PanelTypography.metadata(settings))
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 2: Add the batch operations**

```swift
private func requestBatchDelete() {
    let clips = actionableClips
    guard !clips.isEmpty else { return }
    batchDeletePending = clips          // drives a confirmation alert
}

private func performBatchDelete(_ clips: [Clip]) {
    for clip in clips { store.delete(clip) }   // match the real deletion API used by requestDelete (ClipListView.swift:148)
    selectedClipIDs = []
}

private func runBatchAITitles() {
    let clips = actionableClips.filter { $0.contentKind == .text }
    for clip in clips {
        runAIAction(.title, on: clip)   // match the real AI-title action enum/case used at ClipListView.swift:492-530
    }
}
```

Add `@State private var batchDeletePending: [Clip]? = nil` and an `.alert` mirroring the existing single-clip delete confirmation (`clipPendingDeletion`), worded "Delete N clips?" and calling `performBatchDelete`.

For "Move to category" and "Remove from category", add them to the card context menu (Step 3) rather than the bar to keep the bar compact.

- [ ] **Step 3: Extend the card context menu for batch selection**

In the card's context menu, when `selectedClipIDs.count >= 2`, show batch variants:

```swift
if selectedClipIDs.count >= 2 {
    Button("Paste \(selectedClipIDs.count) Sequentially") { onPasteMany(actionableClips, false, settings.pastePlainTextByDefault) }
    Button("Paste \(selectedClipIDs.count) Combined") { onPasteMany(actionableClips, true, settings.pastePlainTextByDefault) }
    Menu("Move \(selectedClipIDs.count) to Category") {
        ForEach(store.categories) { cat in
            Button(cat.name) {
                for clip in actionableClips { if let id = clip.id, let cid = cat.id { store.fileClip(id: id, intoCategory: cid) } }
                selectedClipIDs = []
            }
        }
    }
    if let activeCategoryID = currentCategoryID {   // non-nil only when viewing a category
        Button("Remove \(selectedClipIDs.count) from Category") {
            for clip in actionableClips { if let id = clip.id { store.setClip(id: id, inCategory: activeCategoryID, false) } }
            selectedClipIDs = []
        }
    }
    Button("Set \(selectedClipIDs.count) Titles with AI") { runBatchAITitles() }
    Divider()
    Button("Delete \(selectedClipIDs.count)", role: .destructive) { requestBatchDelete() }
}
```

`currentCategoryID` is whatever the view already uses to know which category pane is showing (derive from the existing `selection`/`visibleClips` logic at `ClipListView.swift:55-68`). Match `store.setClip(...)`'s real signature for the remove call.

- [ ] **Step 4: Mount the action bar**

In the root VStack, between the content `Divider()` and `footer`, add:

```swift
if selectedClipIDs.count >= 2 { batchActionBar; Divider() }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Manual runtime check**

Relaunch. Select 3 text clips:
- Action bar appears. "Paste Seq." pastes all three into a focused text field in order. "Paste Joined" pastes them newline-joined. PASS.
- Context menu "Move 3 to Category -> X" files all three (single or multi per setting). PASS.
- Inside a category, "Remove 3 from Category" removes all three from it. PASS.
- "Delete 3" prompts "Delete 3 clips?" then removes them. PASS.
- "Set 3 Titles with AI" runs the AI title action per clip; titles update. PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Clippy/UI/ClipListView.swift
git commit -m "feat(select): batch paste/move/remove/delete/AI-title actions"
```

---

## PHASE D - Branding / consistency

### Task D1: Add success and danger theme tokens

**Files:**
- Modify: `Sources/Clippy/Support/ThemePreset.swift` (`ThemeTokens` struct + every preset)

- [ ] **Step 1: Add the properties**

Add to `ThemeTokens`:

```swift
var success: Color
var danger: Color
```

- [ ] **Step 2: Populate every preset**

For each preset constructor (`system`, `cleanLight`, `githubDark`, `dracula`, `materialDarkPlus`, `nord`, `oneDark`, `solarizedDark`, `custom`), supply `success`/`danger`. Use the preset's own palette where defined; otherwise fall back to system semantics:

```swift
success: Color(nsColor: .systemGreen),
danger: Color(nsColor: .systemRed),
```

(For named dark themes, prefer their canonical green/red, e.g. Dracula green `#50FA7B` / red `#FF5555`, Nord `#A3BE8C` / `#BF616A`. System fallback is acceptable where the palette has no defined semantic color.)

- [ ] **Step 3: Build + commit**

Run: `swift build` -> `Build complete!`

```bash
git add Sources/Clippy/Support/ThemePreset.swift
git commit -m "feat(theme): add success/danger semantic tokens"
```

### Task D2: Replace hardcoded colors

**Files:**
- Modify: `Sources/Clippy/UI/ScriptsPanelView.swift:222,226`
- Modify: `Sources/Clippy/UI/SettingsView.swift:179-184`

- [ ] **Step 1: Script status colors via tokens**

In `ScriptsPanelView.swift`, replace `Color(nsColor: .systemGreen)` with `tokens.success` and `Color(nsColor: .systemRed)` with `tokens.danger` (this view reads `tokens` the same way the rest do; if not, add `private var tokens: ThemeTokens { AppSettings.shared.theme }`).

- [ ] **Step 2: Settings tab icon colors via tokens**

In `SettingsView.swift:179-184`, the tab icons use `Color(nsColor: .systemGray/Pink/Blue/...)`. Replace the per-tab hardcoded colors with `tokens.accent` for the selected tab and `tokens.textSecondary` for unselected, so the settings chrome follows the active theme/accent. (Keep distinct per-tab SF Symbols; only the color is unified.)

- [ ] **Step 3: Build + manual check + commit**

Run: `swift build` -> `Build complete!`
Relaunch: Scripts status badges and Settings tab icons now follow the theme. Switch themes -> they recolor.

```bash
git add Sources/Clippy/UI/ScriptsPanelView.swift Sources/Clippy/UI/SettingsView.swift
git commit -m "refactor(theme): route status and tab-icon colors through tokens"
```

### Task D3: Default accent to Clippy Amber

**Files:**
- Modify: `Sources/Clippy/Support/Theme.swift` (`AccentTheme` + its `color`/default)

- [ ] **Step 1: Add the Clippy Amber accent and make it the default**

In `AccentTheme`, add a case `clippyAmber` and map its `color` to `Color(red: 0xE0/255, green: 0xA2/255, blue: 0x3C/255)` (#E0A23C). Set the app's default accent selection to `.clippyAmber`:
- If the default lives in `AppSettings` (an accent key default near line 525), change it to the raw value of `clippyAmber`.
- Ensure the accent picker in Settings lists "Clippy Amber" as the first/most-prominent option.

Keep `system` and all existing accents available - this only changes the default for fresh installs / unset values.

- [ ] **Step 2: Build + manual check + commit**

Run: `swift build` -> `Build complete!`
Fresh-launch (or reset the accent default): selection/active states and the header mark render amber. Existing user accent choices are untouched.

```bash
git add Sources/Clippy/Support/Theme.swift Sources/Clippy/Support/AppSettings.swift
git commit -m "feat(brand): default accent Clippy Amber (#E0A23C)"
```

### Task D4: Consistency polish

**Files:**
- Modify: `Sources/Clippy/UI/PanelHeaderView.swift`, `Sources/Clippy/UI/ClipListView.swift` (search bar, footer)

- [ ] **Step 1: Align metrics**

Make the header, search bar, and footer share the same horizontal padding (12) and the header/footer share the same vertical rhythm. Ensure corner radii on cards (8) and the panel (12, already set at `ClipListView.swift` overlay) are the only two radii in use. Use one SF Symbol weight (`.medium`) for chrome glyphs across header, search bar, and footer.

- [ ] **Step 2: Build + manual check + commit**

Run: `swift build` -> `Build complete!`
Relaunch and eyeball: header, search, panes, and footer read as one app; spacing is even; the paperclip mark + "Clippy" wordmark anchor the top.

```bash
git add Sources/Clippy/UI/PanelHeaderView.swift Sources/Clippy/UI/ClipListView.swift
git commit -m "style(panel): unify spacing, radii, and glyph weights"
```

### Task D5: Final full-pass verification

- [ ] **Step 1: Clean build**

Run: `rm -rf .build && swift build`
Expected: `Build complete!` with zero warnings.

- [ ] **Step 2: Full manual regression**

Walk the entire design "Verification" checklist end to end: header-only drag; all three reorganization drags; single vs multiple category filing; plain/cmd/shift/Cmd-A selection and Esc; sequential and combined paste; batch move/remove/delete/AI-title; setting persistence; amber default; no off-theme colors on the audited surfaces.

- [ ] **Step 3: Final commit if any fixes were needed; otherwise stop.**

---

## Self-review notes (author)

- **Spec coverage:** A (header+drag) -> Tasks A1-A3; B (single/multi category) -> B1-B3; C (multi-select + sequential/combined paste + move/remove/delete/AI titles) -> C1-C5; D (identity, tokens, hardcoded-color removal, amber default) -> D1-D5. All design sections map to tasks.
- **Signature naming:** `fileClip(id:intoCategory:)`, `pasteSequence(_:asPlainText:)`, `pasteCombined(_:separator:asPlainText:)`, `onPasteMany(_:combined:asPlainText:)`, `selectedClipIDs`, `actionableClips`, `batchDeletePending` used consistently across tasks.
- **Known API-shape unknowns** (the implementer must match real signatures, flagged inline): `setClip(...)` add/remove signature, `store.delete(...)` signature, the AI-title action enum case, and the "current category id" accessor. Each is pinned to a real call site (`ClipListView.swift:148`, `:428-463`, `:492-530`, `:55-68`) so the implementer reads the truth rather than guessing.
- **Toolchain:** XCTest can't run here; `swift build` + manual runtime checks are the gate, with two DEFERRED TEST cases noted for the next Xcode-equipped session.

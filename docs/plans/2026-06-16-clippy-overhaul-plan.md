# Clippy Overhaul Plan

Created 2026-06-16. Source: `/claude-mem:make-plan`, grounded in 5 parallel read-only investigations (settings regression, AI assistant, drag/drop, themes/sounds/logging/symbols, build environment) plus a prior swiftui-pro review of all 16 view files.

This plan is written to be executed phase by phase, each in a fresh chat context. Every phase is self-contained: it cites the exact files/lines to touch, the docs to read first, a verification checklist, and anti-pattern guards. Do not skip Phase 0 in any phase that adopts a new API.

---

## Product decisions (locked)

- **Deployment target: raise to macOS 26.** Unlocks Foundation Models (Apple Intelligence on-device LLM) and all 2025 SwiftUI APIs. Accepted cost: drops macOS 14/15 users; requires Xcode 26.
- **MLX: include now.** Add `mlx-swift` and an on-device MLX inference provider alongside the existing network + Ollama providers.

## Environment baseline (verified)

- `Package.swift`: `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`, `.swiftLanguageMode(.v5)` on both targets.
- Dependencies (Package.resolved): GRDB.swift 7.11.0, Sparkle 2.9.3, TOMLKit, swift-markdown-ui 2.4.0 (+ NetworkImage, swift-cmark).
- Build machine: Swift 6.2.4, macOS 26.5.1 (Tahoe), Apple Silicon. **Xcode NOT installed — only Command Line Tools** (`xcodebuild` fails). Pure SwiftPM project, no `.xcodeproj`.
- Tests: 24 files under `Tests/ClippyTests/`, **XCTest** (no Swift Testing). Run with `swift test`.
- Build/package: `scripts/make-app.sh` (`swift build -c release` + bundle + codesign + Sparkle). Appcast: `scripts/make-appcast.sh`.
- Apple-AI today: only Vision (OCR). AI subsystem is network LLM over URLSession: providers `ollama`, `openai`, `anthropic`, `azureFoundry`.

## Hard prerequisite gate

**Install Xcode 26 before any phase that builds against the macOS 26 SDK** (Phases 2, 6, 8, 9, 10). The critical regression fix (Phase 1) and several cleanups build fine on the current Command Line Tools toolchain at the macOS 14 target, so they can land first. `swift build`/`swift test` must be the verification command throughout (no `xcodebuild`).

---

## Phase 0: Documentation discovery (run first inside every API-adopting phase)

Goal: never invent an API. Produce an "Allowed APIs" list with sources before writing code. Deploy discovery subagents (Context7 for third-party, Apple/Microsoft docs for platform) to gather exact signatures for that phase's surface. Consolidate findings, then implement.

Required discovery per surface:

- **Foundation Models (Apple Intelligence):** `import FoundationModels`, `SystemLanguageModel`, `LanguageModelSession`, streaming responses, tool calling, availability (`SystemLanguageModel.default.availability`), guided generation. Source: Apple Developer docs for FoundationModels (macOS 26). Confirm the on-device tool-calling shape so it maps onto the existing `AIToolDefinition`.
- **MLX Swift:** `mlx-swift` and `mlx-swift-examples` (LLM eval) package APIs, minimum macOS, model loading/download, memory. Source: Context7 `ml-explore/mlx-swift` + the examples repo. Confirm the exact minimum platform before pinning.
- **2025 SwiftUI components:** the current native components that replace custom scaffolding (see Phase 7), plus `@Animatable` macro, `@Entry` macro, rich `TextEditor`/`TextField(axis:)`, `ContentUnavailableView`, `Tab` API, scroll APIs. Source: Apple SwiftUI docs.
- **SF Symbols effects (macOS 14+):** `symbolEffect(_:)` (bounce, pulse, variableColor, wiggle, breathe, rotate), `symbolRenderingMode(.palette/.hierarchical/.multicolor)`, `contentTransition(.symbolEffect(...))`, `symbolEffectsRemoved`. Source: Apple SF Symbols / SwiftUI docs.
- **Provider request shapes (re-verify live, do not trust the in-code version comments):** Anthropic Messages streaming (`anthropic-version`, `content_block_delta`/`input_json_delta`), OpenAI Chat Completions streaming deltas, Azure OpenAI `api-version`. Source: each provider's current API docs.
- **Theme palettes (authoritative):** Nord (nordtheme.com spec), GitHub Primer dark (`@primer/primitives` current dark scale), Material 3 dark, plus VSCode-accurate themes to add: One Dark Pro, Dracula (official), Tokyo Night, Solarized. Source: each theme's canonical repo/spec.
- **os.Logger levels:** `Logger.debug/.info/.notice/.warning/.error`, `OSLogType`, privacy interpolation. Source: Apple os/Logger docs.

Anti-patterns to record for each surface: methods that do NOT exist, deprecated parameters, version-gated APIs that need `if #available`. (After raising to macOS 26, most `#available` walls for 2025 APIs become unnecessary — confirm and remove dead gates.)

Deliverable: a short "Allowed APIs" appendix appended to each phase's working notes, with sources cited.

---

## Phase 1: CRITICAL — restore the ability to change anything (do this first, current toolchain)

Root cause (high confidence): `Sources/Clippy/Support/AppSettings.swift:87` declares `let objectWillChange = ObservableObjectPublisher()`. The class is `ObservableObject` and still has 8 live `@Published` properties (`pollingIntervalMs`, `mcpEnabled`, `fontSizeBase`, `panelOpacity`, `captureSoundID`, `keystrokeWarnThreshold`, `onePasswordAutoClearDelaySecs`, `mcpPort`). The explicit `objectWillChange` replaces the compiler-synthesized publisher that `@Published` and `@ObservedObject` rely on, so every settings write persists to UserDefaults but no view re-renders. Symptom: "nothing can be changed."

What to implement:

1. Delete line 87 (`let objectWillChange = ObservableObjectPublisher()`) in `AppSettings.swift`. Let the compiler synthesize `objectWillChange`. The `@AppDefault` subscript's `where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher` constraint still holds (the synthesized publisher IS `ObservableObjectPublisher` whenever `@Published` is present), so `instance.objectWillChange.send()` still compiles and now fires the same publisher views subscribe to.
2. Do NOT remove the `@Published` properties to "make the comment true" — `$pollingIntervalMs` (ClipboardMonitor.start), `$mcpEnabled`/`$mcpPort` (McpServerController) are consumed as Combine projections.
3. Verify clip-edit flow B independently: read `ClipStore.updateText` / `updateImage` / `renameClip` (`Sources/Clippy/UI/ClipStore.swift` ~217/225/290) and confirm each mutation is assigned back to the `@Published private(set) var clips` source of truth (the investigation flagged this as an unread gap; confirm no value-copy-never-assigned bug).

Documentation references: Combine `ObservableObject`/`@Published`/synthesized `objectWillChange` contract; `AppDefault.swift` (full) for the subscript mechanism.

Verification checklist:

- `swift build` clean.
- `swift test` — `AppDefaultTests` and any AppSettings observation tests pass.
- Add a regression test: subscribe to `AppSettings.shared.objectWillChange`, mutate an `@AppDefault` property and a `@Published` property, assert the sink fires for both.
- Manual: launch app, toggle a setting → dependent UI updates immediately; edit a clip → change is visible and persists across relaunch.

Anti-pattern guards: do not reintroduce a hand-rolled `objectWillChange`; do not migrate AppSettings to `@Observable` in this phase (that is Phase 9b, and it interacts with the Combine `$` projections — keep this fix surgical).

---

## Phase 2: Toolchain + deployment-target migration to macOS 26

Prerequisite: Xcode 26 installed. Verify with `xcodebuild -version` and `xcrun --sdk macosx --show-sdk-version` (expect 26.x).

What to implement:

1. `Package.swift`: change `platforms: [.macOS(.v14)]` → `[.macOS(.v26)]`. Keep `swift-tools-version` and `.swiftLanguageMode(.v5)` for now (Swift 6 language-mode migration is explicitly out of scope here to limit blast radius; the manifest comment about AppKit/Carbon callbacks still applies).
2. `swift build` and `swift test` against the macOS 26 SDK. Fix any newly-surfaced deprecations the SDK bump reveals.
3. Audit `if #available(macOS ...)` walls now made dead by the higher floor; remove dead branches.
4. Update `scripts/make-app.sh` / any bundle Info.plist `LSMinimumSystemVersion` to 26.0.
5. Update `docs/ROADMAP.md` / `docs/CHANGELOG.md` to record the floor change and the dropped-OS consequence.

Verification checklist: clean `swift build` + full `swift test` on the macOS 26 SDK; grep for `#available(macOS` shows no dead gates; app launches on macOS 26.

Anti-pattern guards: do not flip to Swift 6 language mode opportunistically; do not adopt 2025 APIs yet (later phases) — this phase only moves the floor and proves the build stays green.

---

## Phase 3: Logging system with configurable level

Current state: `Sources/Clippy/Support/ClippyLog.swift` is a real dual-sink logger (os.Logger per area + rotating file at `~/Library/Application Support/Clippy/Logs/clippy.log`), but it has only `info`/`error`/`syncWrite` and NO level concept or filtering. No `logLevel` setting exists. Stray `NSLog("Clippy: ...")` at `ClipStore.swift:232,284`.

What to implement (copy the os.Logger level mapping from Phase 0 discovery):

1. In `ClippyLog.swift`: add `enum LogLevel: Int, Comparable, CaseIterable { case verbose, debug, info, warning, error }`. Add methods `verbose/debug/info/warning/error(_:category:)`. Map to `Logger.debug/.debug/.info/.warning/.error` (or `.notice` as appropriate). Gate BOTH sinks on a configurable threshold (`if level >= currentThreshold`). Keep the serial `fileQueue`.
2. `AppSettings.swift`: add `@AppDefault var logLevel: LogLevel` (store rawValue; default `.info`). Wire `ClippyLog`'s threshold to read this (e.g. a `static var threshold` updated on change, or read through a closure).
3. `SettingsView.swift`: add a "Logging" control (a `Picker` over `LogLevel.allCases`) in a sensible tab. Use native `Picker`/`LabeledContent`.
4. Boy-scout: replace `ClipStore.swift:232,284` `NSLog` with `ClippyLog.error(..., category: .storage)`.

Documentation references: Phase 0 os.Logger findings; existing `ClippyLog.swift` structure; `AppDefault.swift`.

Verification checklist: `swift build`/`swift test` clean; setting the level to `.warning` suppresses debug/info file writes (assert in a test by reading the log file); the level Picker persists and takes effect live (validates Phase 1 too).

Anti-pattern guards: do not log secrets/API keys; respect os.Logger privacy interpolation; do not block callers (keep async file sink).

---

## Phase 4: Drag-and-drop reorder fixes

Persistence and reorder math are CORRECT and need no change: `Storage/ReorderIDs.swift`, `ClipDatabase+Categories.swift` (`moveCategory`, `moveClip`, `fileClip`→`setClip`), and the `ValueObservation` republish in `ClipStore`. The defects are in the gesture/drop wiring.

Defect A — drags often never start (clips reorder + clip-into-category): `ClipListView.swift` `card(for:)` (~:502-517) stacks `.draggable` (via `CategoryReorderModifier`) with two `.onTapGesture` (count:2 at :516, unconditional at :517). On macOS the plain taps contend with the AppKit drag session and the unconditional tap claims the press, so the drag frequently never begins.

Defect B — category reorder is swallowed: category rows carry TWO `.dropDestination(for: String.self)` — the outer `.reorderDropDestination(kind:"cat")` at `CategorySidePane.swift:37` and the inner clip-filing `.dropDestination(for: String.self)` at `:135`. The inner one wins targeting; its `return false` for `reorder:cat:` tokens does NOT cascade to the outer destination, so `store.moveCategory` is never called.

What to implement (verify the two behavioral claims against current SwiftUI macOS docs in Phase 0 first):

1. Defect B: collapse the two category-row drop destinations into ONE `.dropDestination(for: String.self)` whose closure routes by token prefix: `reorder:cat:` → `store.moveCategory`; `clip:` / `reorder:clip:` → `store.fileClip`. Remove the outer/inner stacking; reuse the `kind` tag from `ReorderableForEach` for clean disambiguation.
2. Defect A: stop stacking `.onTapGesture` against `.draggable`. Move selection/activation to a gesture that explicitly arbitrates click-vs-drag (e.g. a single `.gesture`/`.simultaneousGesture` proven to let the drag initiate, or drive clicks from an AppKit click outside the draggable subview). Verify the drag still starts after the change.
3. Keep payloads as `String` tokens (`clip:<id>`, `reorder:clip:<id>`, `reorder:cat:<id>`) — the type is fine; the routing was the problem.

Documentation references: Phase 0 SwiftUI drag/drop findings; `ReorderableForEach.swift` (full), `ClipCardView.swift` `CategoryReorderModifier`, `CategorySidePane.swift:37,131-154`.

Verification checklist (manual, in the running app — this is gesture-level and cannot be unit-tested fully):

- Reorder clips within a category: drag starts, row moves, new order persists across relaunch.
- Reorder categories: drag starts, order changes, persists.
- Drag a clip from History onto a category row: clip is filed (appears under that category), persists.
- Existing `ReorderIDsTests` / `ClipDatabase` tests still pass (`swift test`).

Anti-pattern guards: never put two `.dropDestination` of the same type on one view; do not reintroduce `.highPriorityGesture` on the draggable (observation 13618 proved it hard-blocks the drag); do not mutate a sorted/derived copy (the source-of-truth + ValueObservation path is already correct — keep it).

---

## Phase 5: AI Assistant — validate, fix configuration UX, harden providers

Finding: the network AI path is structurally complete and compiles; keys ARE read from Keychain and sent with the right per-provider header; errors are surfaced into the bubble (not swallowed); streaming concurrency is correct. The most likely reason it "never worked" is configuration: `aiEnabled` defaults to `false` (`AppSettings.swift:306,573`), the API key must be explicitly saved per-provider (keychain account `ai.<provider>.apiKey`), and the Azure endpoint default is a `YOUR-RESOURCE` placeholder. Phase 1 also matters: a dead UI made the enable toggle look like a no-op.

What to implement:

1. Re-test live after Phase 1: enable AI, save a real key, send a message; confirm tokens stream into the bubble. Capture the actual result (this is the "validate" the user asked for — show evidence).
2. Make not-configured actionable: confirm the `notConfiguredState` view renders the `state = .notConfigured(msg)` message with an "Open Settings" affordance; if it does not visibly show the message, fix it.
3. Validate provider request shapes against current docs (Phase 0): Anthropic streaming events, OpenAI deltas, Azure `api-version`. Update stale model defaults (`gpt-4o-mini`, `claude-3-5-haiku-latest`) only after confirming against the account; do not guess.
4. Azure: reject the `YOUR-RESOURCE` placeholder endpoint in `AIService.fromSettings` so the failure message is precise instead of a DNS error.
5. Keychain robustness: on ad-hoc/unsigned dev builds the keychain item access can shift across rebuilds (`read` → nil → `.notConfigured`); note this as a likely "worked once then stopped" cause and confirm the account/access attributes are stable, or surface a clear "key not found, re-enter" state.

Documentation references: `AIAssistantPanelView.swift`, `AIAgent.swift`, `AIStreaming.swift`, `AIProviders.swift`, `AIProvider.swift`, `AIService.swift`, `SettingsView.swift` AI tab (~:800-1015). Phase 0 provider-API findings.

Verification checklist: live send produces streamed output for at least one configured provider (evidence captured); `AIEngineTests`/`StreamParserTests`/`WireMessagesTests` pass; a deliberately bad key shows a readable error in the bubble; switching provider without a saved key shows the not-configured state with an Open-Settings action.

Anti-pattern guards: do NOT invent request/response shapes — verify each against live docs; do not swallow errors; do not store keys in UserDefaults/`@AppStorage` (keychain only).

---

## Phase 6: Apple Intelligence (Foundation Models) + MLX on-device providers

Prerequisite: Phase 2 (macOS 26) landed. Read Phase 0 FoundationModels + MLX findings first.

What to implement (extend the existing provider abstraction — the AI layer is already factory-based via `AIAgentProviderFactory`):

1. Add an `appleIntelligence` provider backed by `FoundationModels` (`SystemLanguageModel` / `LanguageModelSession`), conforming to the same streaming + tool-calling interface the other providers implement. Gate creation on `SystemLanguageModel.default.availability` and surface an unavailable state (no Apple Intelligence hardware / disabled) cleanly.
2. Add an `mlx` provider using `mlx-swift` (pin after confirming its minimum macOS in Phase 0). Implement model selection/download/management and on-device inference behind the same provider interface. Add `mlx-swift` to `Package.swift` dependencies + Package.resolved.
3. Extend `AIProviderKind` and the Settings AI tab to expose both new providers with appropriate config (model picker for MLX, availability note for Apple Intelligence).
4. Map both onto the existing `AIToolDefinition` tool-calling so the assistant's tools work identically across providers.

Documentation references: Phase 0 FoundationModels + MLX appendix; existing `AIProvider.swift`/`AIAgent.swift` provider/factory pattern to copy.

Verification checklist: `swift build`/`swift test` clean on macOS 26 SDK; Apple Intelligence provider returns a streamed completion on capable hardware (evidence) and degrades gracefully where unavailable; MLX provider loads a small model and returns output; provider switch in Settings works (validates Phase 1/3).

Anti-pattern guards: no `#available` dead code below macOS 26; do not block the main actor during model load (use `task()` + async); handle MLX model-download failure and memory pressure explicitly (no silent `try?`); ship no model weights in the repo (download/manage at runtime).

---

## Phase 7: Themes overhaul

Findings: the per-color custom controls are gated by `SettingsView.swift:397` `if settings.themePreset == .custom`, so picking any named preset hides all 10 custom rows. The `Theme.tokens(_:)` resolver (~`ThemePreset.swift:163`) already layers an accent override on top of fixed palettes — the natural hook for per-token overrides. Several preset palettes are inaccurate: Nord's `scrollBackground/headerBar/footerBar/sidebar = #272B35` is not a Nord color; GitHub Dark uses legacy Primer values; Material Dark+ flagged. `success`/`danger` are hardcoded `systemGreen`/`systemRed` in custom mode.

What to implement (use authoritative palettes from Phase 0):

1. Un-gate custom colors: let users tweak any token ON TOP of a selected preset (do not hide the controls outside `.custom`). Implement by layering per-token overrides in `Theme.tokens(_:)` the same way accent already overrides — preset provides the base, user overrides win where set, "reset to preset" clears an override.
2. Correct the existing presets to authoritative values: Nord (fix the `#272B35` tokens to real polar-night values `#2E3440/#3B4252/#434C5E/#4C566A`), GitHub Dark (current `@primer/primitives` dark scale), Material 3 dark.
3. Add VSCode-accurate presets the user named as missing: One Dark Pro, Dracula (official), Tokyo Night, Solarized — exact hex from each theme's canonical source.
4. Make `success`/`danger` user-customizable in override mode (currently hardcoded).
5. Keep the centralized `ThemeTokens` consumption (views already read `tokens.*`) — no view-level color hardcoding.

Documentation references: `ThemePreset.swift` (`ThemeTokens`, `fixedTokens`, `Theme.tokens`), `SettingsView.swift:341-415,529-585` (AppearanceSettingsTab, `CustomColorRow`); Phase 0 authoritative-palette appendix.

Verification checklist: selecting a preset still shows editable color controls; overriding a token recolors the app live (validates Phase 1); "reset to preset" restores the base; a snapshot/diff test of preset hex values matches the authoritative source; no `NSColor`/hardcoded colors leak into views.

Anti-pattern guards: do not re-hide controls behind `themePreset == .custom`; do not invent hex values — cite the source for each; keep contrast (text vs background) within WCAG AA for each shipped preset.

---

## Phase 8: All Apple system sounds selectable

Finding: `SoundCatalog.swift` builds the "Classic" group from a hardcoded 14-name allowlist in `CaptureSound.swift`; it enumerates `~/Library/Sounds` and `/Library/Sounds` for custom sounds but NOT `/System/Library/Sounds/`. The picker (`SettingsView.swift:676-707`) is already group-driven and will pick up new options automatically.

What to implement:

1. In `SoundCatalog.build()`, enumerate `/System/Library/Sounds/` (mirror the existing `userSoundDirectories()` + `isSoundFile()` pattern) and add every system sound as a `SoundOption` in a "System" group, addressed by `system:<name>` (resolvable via `NSSound(named:)`) or `file:<abspath>` as appropriate.
2. Keep the curated CoreAudio UI sounds group if still desired; de-duplicate against the enumerated set.
3. Leave `SoundPlayer.resolve`/`play` and the picker UI unchanged (they already handle `system:`/`file:` and are group-driven).

Documentation references: `SoundCatalog.swift` (full), `CaptureSound.swift` (full), `SettingsView.swift:676-707`.

Verification checklist: the Sound picker lists every `.aiff` in `/System/Library/Sounds/`; selecting and previewing each plays; selection persists and plays on capture (`ClipboardMonitor.swift:191`); a test asserts the catalog count matches the directory contents.

Anti-pattern guards: do not hardcode a new allowlist — enumerate the directory; handle missing files gracefully; do not block on disk I/O on the main actor during catalog build.

---

## Phase 9: SwiftUI SDK audit + native-component migration + review-findings cleanup

This phase delivers the "use native Apple components, consistent feel, latest SwiftUI" goal and folds in the swiftui-pro review findings. Read Phase 0 SwiftUI-2025 + SF-Symbols appendix first.

### 9a — Replace custom/scaffolded UI with native components

Audit every view in `Sources/Clippy/UI` and `Sources/Clippy/AI` and replace hand-rolled UI where a native component exists:

- Empty/missing states → `ContentUnavailableView` (e.g. `ClipListView.emptyState` ~:702-714; search no-results → `ContentUnavailableView.search`).
- Icon+text rows → `Label` instead of `HStack`.
- Multiline text entry → `TextField(axis: .vertical)` (gives placeholder) instead of `TextEditor` where not full-screen (`SettingsView.swift:735`, evaluate `AIActionsManagerView` template editor).
- Title+control layout → `LabeledContent`; sliders/toggles in `Form` wrapped correctly.
- Tabs → the `Tab` API; ensure `TabView(selection:)` binds an enum, not Int/String.
- Replace deprecated modifiers: `foregroundColor`→`foregroundStyle`, `cornerRadius()`→`clipShape(.rect(cornerRadius:))`, `overlay(_:alignment:)`→`overlay(alignment:content:)`.

### 9b — Observation modernization (now that the floor is macOS 26)

Migrate `AppSettings` and the stores from `ObservableObject`/`@Published`/`@ObservedObject`/`@StateObject` to `@Observable` + `@State`/`@Bindable`/`@Environment`, which also resolves the missing-`import Combine` findings (`AIActionsView.swift`, `AIAssistantPanelView.swift`). CRITICAL ordering: the Combine `$` projections (`ClipboardMonitor` `$pollingIntervalMs`; `McpServerController` `$mcpEnabled`/`$mcpPort`) must be rewired to `@Observable` (e.g. `Observations`/async streams or explicit `onChange`) BEFORE removing `@Published`, or those subscribers break. `@Observable` classes must be `@MainActor`.

### 9c — Review-findings cleanup (mechanical, from the swiftui-pro pass)

- Concurrency (no GCD / no `Task.sleep(nanoseconds:)`): `SettingsView.swift:187-202` (`DispatchQueue.main.async`→`Task { @MainActor }`), `ClipListView.swift:564,666` and `ClipEditorView.swift:184` (`asyncAfter`→`Task`+`Task.sleep(for:)`), `OnePasswordView.swift:409` (`Task.sleep(nanoseconds:)`→`Task.sleep(for:)`).
- `IconPickerView.swift:43`: user-text search `.lowercased().contains` → `localizedStandardContains`.
- `AIActionsManagerView.swift:278,307`: `String(format: "%.1f", ...)` → `Text(value, format: .number.precision(.fractionLength(1)))`.
- `Color(nsColor:)` → SwiftUI `Color`: `ClipCardView.swift:91,359`, `CategorySidePane.swift:175,189`, `AIAssistantPanelView.swift:449,468`.
- `Binding(get:set:)` in body → `@State`/`@Binding`+`onChange` or item-bound presentation: `CategorySidePane.swift:104-109` (use `.popover(item: $editingCategory)`), `ScriptsPanelView.swift:64-68`, `AIActionsManagerView.swift:100-103`, `SettingsView.swift` slider round-trips.
- `ForEach(Array(x.enumerated()), id:\.offset)` → direct iteration or `Identifiable` element: `SettingsView.swift:610`, `ClipCardView.swift:295`, `OnePasswordView.swift:160`, `CategoryEditorView.swift:48`, `AIAssistantPanelView.swift:491`.
- One-type-per-file: split `SettingsView.swift` (~11 types) and the smaller offenders (`ActionIconView` out of `IconPickerView`, `AIActionEditorView` out of `AIActionsManagerView`, `AIActionRunner`/`AIActionSheet`, the 5 types in `AIAssistantPanelView`).
- Body extraction: pull computed `some View` helpers into dedicated `View` structs (`SettingsView` sidebar/detail/footer, `PanelHeaderView.headerButton`, `ClipCardView.cardBackground`).
- `PanelHeaderView` observation gap: it reads `AppSettings.shared` directly with no observation — after 9b it should observe via `@Environment`/`@Bindable`.

Documentation references: Phase 0 SwiftUI-2025 + the swiftui-pro reference rules; the per-file findings above.

Verification checklist: `swift build`/`swift test` clean; grep guards return zero hits: `foregroundColor(`, `cornerRadius(`, `DispatchQueue`, `Task.sleep(nanoseconds`, `String(format:`, `Color(nsColor:`, `Binding(get:`, `Array(.*enumerated())`; each file declares one top-level type; app runs with all states (loading/empty/error/success) rendering; settings/edits still live-update after the `@Observable` migration.

Anti-pattern guards: do the 9b migration in dependency order (rewire `$` subscribers first); do not break the Phase 1 fix; no `AnyView` except the documented `CategoryReorderModifier` exception; keep one design system.

---

## Phase 10: SF Symbols — dynamic, theme-shaded, animated

Finding: ZERO modern symbol APIs in the codebase (no `symbolRenderingMode`, `symbolEffect`, `.palette`/`.hierarchical`, `contentTransition`). ~58 `Image(systemName:)` across 12 files, mostly monochrome; some use non-theme raw colors (`OnePasswordView.swift:111,146,179`). A `reduceMotion` env value is already threaded (`ClipCardView.swift:141-142`, `ClipListView.swift:274,293`, `ReorderableForEach.swift:117,127`).

What to implement (copy exact APIs from Phase 0):

1. Apply `symbolRenderingMode(.palette)`/`.hierarchical`/`.multicolor` with theme tokens (`.foregroundStyle(tokens.accent, tokens.textSecondary)`) so symbols are colored/shaded by the active theme.
2. Add purposeful `symbolEffect(...)` (bounce/pulse/variableColor) and `contentTransition(.symbolEffect(...))` for state changes (copy success/run/error/loading), each gated on the existing `reduceMotion` (replace large motion with opacity when reduced).
3. Migrate the non-theme raw symbol colors to tokens (`OnePasswordView.swift:111,146,179`).
4. Highest-density targets first: `ClipCardView.swift`, `CategorySidePane.swift`, `OnePasswordView.swift`, `AIAssistantPanelView.swift`.

Documentation references: Phase 0 SF-Symbols appendix; existing `reduceMotion` usage sites to mirror.

Verification checklist: symbols recolor when the theme changes (validates Phase 1/7); animations play on the relevant state transitions and are suppressed under Reduce Motion; `swift build` clean; visual pass in the running app.

Anti-pattern guards: animations must respect `reduceMotion`; do not animate continuously without purpose; keep symbol colors flowing from `ThemeTokens`, not literals.

---

## Phase 11: Final verification

1. Full `swift build -c release` and `swift test` green on the macOS 26 SDK.
2. Anti-pattern grep sweep (zero hits): `foregroundColor(`, `cornerRadius(`, `DispatchQueue`, `Task.sleep(nanoseconds`, `String(format:`, `Color(nsColor:`, `Binding(get:`, `NavigationView`, `PreviewProvider`, dead `#available(macOS 1`.
3. Manual end-to-end in the built app: change a setting (live update), edit a clip (persists), reorder clips + categories, file a clip into a category, send an AI message on each provider including Apple Intelligence + MLX, switch themes and tweak a token, pick a new system sound, change log level and confirm the file output, observe theme-shaded animated symbols.
4. Confirm each implementation matches the Phase 0 "Allowed APIs" (no invented methods/params).
5. Update `docs/CHANGELOG.md` and `docs/ROADMAP.md`; package via `scripts/make-app.sh`; regenerate appcast if releasing.

---

## Execution notes

- **Order:** Phase 1 first (unblocks everything, current toolchain). Then install Xcode 26 → Phase 2. Phases 3–11 after the floor is raised. Within that, 3/4/7/8 are largely independent and can run in parallel contexts; 5→6 is sequential (validate the network path before adding on-device providers); 9b (observation migration) should precede 10 so theme-shaded symbols re-render correctly.
- **Each phase ends green:** `swift build` + `swift test` pass and evidence is captured before moving on. No phase claims done without running it.
- **Verification command is always `swift build` / `swift test`** — never `xcodebuild` (no Xcode project; pure SwiftPM).

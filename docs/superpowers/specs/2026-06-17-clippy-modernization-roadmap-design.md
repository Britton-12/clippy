# Clippy Ground-Up Modernization Roadmap

- Date: 2026-06-17
- Status: Approved design (meta-spec). Each phase below is its own sub-project with its own implementation plan.
- Branch base: `feature/panel-redesign` (current working branch: `feature/clips-files-grid-search-ai`)
- Owner: jerry

## Goal

Modernize the entire Clippy macOS app against current Apple platforms (macOS 26 Tahoe, Swift 6.2 toolchain) without one giant unreviewable change. The work is decomposed into six sequential phases. Each phase is behavior-preserving unless its objective is an explicit feature add, ships with green build and tests, and is verified with evidence before the next phase starts.

This document is the single source of truth for the effort. It does not contain implementation-level steps; those live in per-phase plans produced by the writing-plans flow.

## Scope and decisions (locked)

- Deliverable shape: roadmap first, then phased execution. (confirmed)
- Pillars in scope: Liquid Glass / macOS 26 design, Swift 6 strict concurrency, Apple Intelligence via FoundationModels, SF Symbols 7 + Observation. (confirmed)
- Platform floor: macOS 26 only. Already the floor in `Package.swift` (`platforms: [.macOS(.v26)]`). No backward-compat gating required, so Liquid Glass and FoundationModels can be hard dependencies.
- AI: keep existing cloud providers. Add on-device FoundationModels as an additional provider, not a replacement.
- Xcode Coding Intelligence: documented in this spec (see appendix). The user configures the IDE manually.
- Phase order: 0, 1, 2, 3, 4, 5 in numerical order. (confirmed)
- Execution style: atlas-style. Independent work runs through subagents; every claimed fix is independently verified with build/test evidence before it is called done.

## Current state (assessed 2026-06-17)

Source: three read-only codebase assessments plus three grounded Apple-docs research files in `docs/superpowers/research/`.

App shape: SwiftUI + AppKit menubar clipboard manager. About 65 Swift files, ~13.5k LOC. Swift tools 6.2, language mode pinned to `.v5` in both targets. Dependencies: GRDB 7, Sparkle, TOMLKit, MarkdownUI.

Subsystem snapshot:

- State management: 100% Combine. `ObservableObject`/`@Published` in 9+ files. `ClipStore` (`Sources/Clippy/UI/ClipStore.swift:11`) and `AppSettings` (`Sources/Clippy/Support/AppSettings.swift:80`) are the central stores. Zero `@Observable` adoption.
- Materials and glass: `PanelMaterialStyle` enum exists (`Sources/Clippy/Support/Theme.swift:108`) mapping to `Material`, but it is barely wired. Most backgrounds are flat `Color`. No `glassEffect`, no `GlassEffectContainer`, no `NSVisualEffectView`.
- SF Symbols: 54 symbol usages across 10 files; about 9% have effects (`.bounce`, `.replace` only). No `symbolRenderingMode`, no variable color. Animations already gate on `reduceMotion` in `ClipCardView`.
- HIG: no `NavigationSplitView`/`NavigationStack`, `Form` only in `SettingsView`, no `ContentUnavailableView`. Toolbars present in 8 files.
- Large files (single-responsibility violations): `SettingsView` 1397 LOC (6 settings domains + 2 export helpers in one file), `ClipListView` 1044 (list + search/filter + reorder + context menu), `ClipCardView` 640 (display + inline edit + drag + category UI), `ClipEditorView` 516 (text + image editors + metadata).
- AI architecture (clean): `AIProvider` protocol (`Sources/Clippy/AI/AIProvider.swift:44`), `AIAgentProvider` adds tool-calling (`Sources/Clippy/AI/AIAgent.swift:14`), `AITool` + `AIToolRegistry` (`Sources/Clippy/AI/AIToolDefinition.swift`), `AIProviderFactory.make` (`Sources/Clippy/AI/AIProviders.swift:150`). Cloud providers: OpenAI, Anthropic, Ollama, Azure Foundry. Streaming via `AsyncThrowingStream` with an idle watchdog (`Sources/Clippy/AI/AIStreaming.swift`). Built-in tools (search clips, create clip, list scripts, run script) are provider-agnostic.
- Swift 6 friction: about 11 points across Carbon hotkeys (`HotKeyCenter.swift`), CGEvent (`KeystrokeService.swift`, `PasteService.swift`), Accessibility (`CaretLocator.swift`), NSPasteboard polling (`ClipboardMonitor.swift`), `AppSettings` ObservableObject, `ClipDatabase` singleton + GRDB closure sendability, and GCD usage. `ActivityClock` uses `NSLock` + `@unchecked Sendable` (`Sources/Clippy/AI/AIStreaming.swift:79`).
- Discrepancy to verify: one assessment flagged `HotKeyCenter` as capturing self unsafely; another found it already uses the correct `Unmanaged` round-trip plus `Task { @MainActor in }` pattern. Phase 0 resolves this before estimating Phase 5.

## Target state (grounded in current Apple docs)

Citations live in the research files. Summary of the load-bearing facts:

- Liquid Glass is the controls and chrome layer; `Material` is the background layer. On macOS 26, toolbars, `NavigationSplitView` sidebars, sheets, `.inspector`, and `MenuBarExtra(.window)` adopt Liquid Glass automatically. Reserve manual `.glassEffect(_:in:)` for custom floating UI, group siblings in `GlassEffectContainer(spacing:)`, and use concentric corners (`.rect(cornerRadius:style:.concentric)`). Never glass-on-glass. A custom non-hierarchical `foregroundStyle` disables vibrancy over material, so keep `.secondary`/`.tertiary` for legible text. Under Reduce Transparency / Increase Contrast, glass and material go more opaque; verify contrast in both states.
- FoundationModels: macOS 26.0+, on-device only. Gate every entry point on `SystemLanguageModel.default.availability` (`.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`) with a non-AI fallback. Hard 4096-token context window per session covers instructions + prompts + outputs + tool schemas + `@Generable` schemas; long-clip transforms must chunk-and-combine. A `LanguageModelSession` serves one request at a time (guard with `isResponding`). Use `@Generable`/`@Guide` for structured extraction and the `Tool` protocol (must be `Sendable`). No web access and lower quality than cloud, which is why cloud stays.
- Swift 6: enable `-strict-concurrency=complete` as warnings first, isolate AppKit delegate protocols with `@MainActor`/`@preconcurrency`, then flip the target language mode. For C-interop use the `Unmanaged` userdata round-trip plus a main-actor hop, `Mutex` (macOS 15+), `nonisolated(unsafe)` for lock-guarded globals, and `MainActor.assumeIsolated` for synchronous callbacks.
- Observation: `@Observable @MainActor final class` injected via `.environment(...)` and read with `@Environment`/`@Bindable`. Gains per-property update tracking and implicit `Sendable`, which eases the eventual Swift 6 flip. Watch the computed-property and `@ObservationIgnored` gotchas.
- SF Symbols 7: `.drawOn`/`.drawOff` and `.breathe`/`.wiggle`/`.rotate` are the macOS 26 generation effects; `.replace` (Magic Replace), `.variableColor`, `.pulse`, `.bounce` go back to macOS 14. Color via `.symbolRenderingMode(.hierarchical/.palette/.multicolor/.monochrome)` and palette gradients via `.foregroundStyle(...)`.

## Phases

Each phase has an objective, in-scope list, out-of-scope list, key APIs, primary files, a single failable verification gate, and risks. Effort numbers are rough planning estimates, not commitments.

### Phase 0: Foundations and guardrails

- Objective: make the rest of the work safe and measurable. No user-visible change.
- In scope:
  - Confirm a clean baseline: `swift build` and `swift test` both green; record evidence.
  - Add shared helpers: a `glassEffectWithFallback` view modifier and small symbol-effect helpers, so later phases have consistent call sites.
  - Quick win: replace `ActivityClock`'s `NSLock` + `@unchecked Sendable` with `OSAllocatedUnfairLock` (`Sources/Clippy/AI/AIStreaming.swift:79`).
  - Turn on `-strict-concurrency=complete` as warnings (not errors) and capture the full compiler friction inventory to a file. This replaces estimates with ground truth and resolves the `HotKeyCenter` discrepancy.
  - Document Xcode Coding Intelligence setup (already in this spec appendix; verify steps against the installed Xcode 26).
- Out of scope: any behavior change, any glass or symbol restyling, flipping the language mode.
- Key APIs: `OSAllocatedUnfairLock`, Swift settings `-strict-concurrency=complete`.
- Primary files: `Package.swift`, `Sources/Clippy/AI/AIStreaming.swift`, a new `Sources/Clippy/Support/GlassEffect+Fallback.swift` (or similar), a new `Sources/Clippy/Support/SymbolEffect+Helpers.swift`.
- Verification gate: build and tests green; the captured warning inventory exists and is non-empty (or explicitly empty, which itself is signal).
- Risks: low. Warnings could be noisy; that is the point, they get triaged in Phase 5.
- Effort: 1 to 2 days.

### Phase 1: Observation migration

- Objective: move central state to the Observation framework. Behavior-preserving.
- In scope:
  - `ClipStore` and `AppSettings` to `@Observable @MainActor final class`.
  - Cascade the 9 consuming views from `@StateObject`/`@ObservedObject`/`@EnvironmentObject` to `@State`/`@Environment`/`@Bindable`.
  - Replace `.environmentObject(...)` injection with `.environment(...)`.
- Out of scope: splitting files (Phase 2), any visual change.
- Key APIs: `@Observable`, `@ObservationIgnored`, `@Bindable`, `@Environment`, `.environment(_:)`.
- Primary files: `Sources/Clippy/UI/ClipStore.swift`, `Sources/Clippy/Support/AppSettings.swift`, plus `SettingsView`, `ClipListView`, `ClipCardView`, `ClipEditorView`, `ScriptsPanelView`, `ScriptsView`, `OnePasswordView`, `CategorySidePane`, and the app entry/`AppDelegate` injection sites.
- Verification gate: build and tests green; manual smoke confirms settings persist and clip list reacts to changes exactly as before.
- Risks: medium-low. `AppSettings` has many properties tied to UserDefaults; the migration must preserve binding semantics and avoid feedback loops with `@ObservationIgnored` where appropriate.
- Effort: 3 to 5 days.

### Phase 2: File decomposition and HIG

- Objective: split the four oversized views and adopt current HIG containers. Behavior-preserving structural refactor.
- In scope:
  - `SettingsView` 1397 LOC: extract one component per settings domain (General, Storage, Keyboard, Keys, Security, Advanced) and move `ExportClip`/`ExportDocument` to their own file.
  - `ClipListView` 1044: extract search/filter into a dedicated container; extract the context menu into a reusable component.
  - `ClipCardView` 640: extract metadata, pin control, and category UI sub-views.
  - `ClipEditorView` 516: extract the text editor, image editor, and metadata pane.
  - Adopt `ContentUnavailableView` for empty states (clips, search-no-results, scripts).
  - Adopt `NavigationSplitView` for the settings layout.
- Out of scope: glass and symbol restyling (Phase 3), any new feature.
- Key APIs: `ContentUnavailableView`, `NavigationSplitView`, `@ViewBuilder` extraction.
- Primary files: the four large UI files plus the new component files they spawn.
- Verification gate: build and tests green; each split view renders identically (manual before/after of settings, list, card, editor). No file over ~300 LOC without a noted reason.
- Risks: medium. Largest surface area; the risk is accidental behavior drift during extraction. Mitigate by extracting one view at a time with a smoke check between each.
- Effort: 5 to 8 days.

### Phase 3: Liquid Glass and SF Symbols 7

- Objective: adopt the macOS 26 design language. User-visible polish.
- In scope:
  - Apply `.glassEffect` to genuinely custom floating chrome only (the paste panel, the AI assistant panel overlays), grouped in `GlassEffectContainer`. Let system containers (toolbars, sidebars, sheets, `MenuBarExtra(.window)`) adopt glass automatically.
  - Wire `Material` backgrounds correctly behind panels via the existing `PanelMaterialStyle`.
  - Concentric corners on nested controls.
  - `.buttonStyle(.glass)` where appropriate.
  - Backfill `symbolEffect` (gate `.drawOn`/`.breathe` behind `reduceMotion`), add `symbolRenderingMode` and variable color where it improves legibility.
- Out of scope: structural refactors (done in Phase 2), AI work.
- Key APIs: `.glassEffect(_:in:)`, `GlassEffectContainer`, `glassEffectID`, `.buttonStyle(.glass)`, `.rect(cornerRadius:style:.concentric)`, `.symbolEffect`, `.symbolRenderingMode`.
- Primary files: panel views (`PanelController`, `PastePanel`, `AIAssistantPanelView`), `Theme.swift`, `ThemedBackground.swift`, `PanelHeaderView`, and the symbol-bearing views.
- Verification gate: build green; visual check with Reduce Transparency and Increase Contrast both off and on; no glass-on-glass; contrast legible in both states.
- Risks: medium. Over-applying glass is the top documented gotcha; the container grouping must be correct for performance and correct blending.
- Effort: 4 to 7 days.

### Phase 4: Apple Intelligence (FoundationModels)

- Objective: add an on-device AI provider alongside cloud. New feature.
- In scope:
  - New `Sources/Clippy/AI/AIFoundationModelsProvider.swift` with a provider conforming to `AIProvider` and an agent provider conforming to `AIAgentProvider`.
  - Add an `AIProviderKind` case (display name "Apple (on-device)", no API key) and a `AIProviderFactory.make` branch.
  - Availability gating on `SystemLanguageModel.default.availability` with a clear non-AI fallback and user messaging.
  - Context-window strategy: chunk-and-combine for `summarize`/`rewrite` of long clips; keep instructions and `@Guide` text terse; serialize requests with `isResponding`.
  - Bridge existing `AITool` definitions to the FoundationModels `Tool` protocol so the on-device path reuses search-clips/create-clip/etc.
  - Settings UI to select the on-device provider.
- Out of scope: changing cloud providers, MCP changes.
- Key APIs: `SystemLanguageModel`, `LanguageModelSession`, `session.respond(to:)`, `session.streamResponse(to:)`, `@Generable`, `@Guide`, `Tool`.
- Primary files: new provider file, `AIProvider.swift` (enum), `AIProviders.swift` (factory), AI settings UI, a `Tool` bridge.
- Verification gate: build green; on a capable machine, the on-device provider answers a prompt and runs at least one tool; on an ineligible machine the availability fallback is exercised and does not crash; a long-clip summarize does not throw `exceededContextWindowSize`.
- Risks: medium. The 4096-token window is the real constraint; chunking logic needs tests. Tool bridging must preserve the existing registry contract.
- Effort: 5 to 8 days.

### Phase 5: Swift 6 strict concurrency flip

- Objective: flip both targets to Swift 6 language mode with strict concurrency. Behavior-preserving.
- In scope (driven by the Phase 0 warning inventory):
  - Isolate AppKit delegates and `NSStatusItem`/`MenuBarExtra` with `@MainActor`.
  - Wrap Carbon hotkeys, CGEvent, and Accessibility C-interop with the verified `Unmanaged` + main-actor-hop pattern; `Mutex`/`nonisolated(unsafe)` for the true barriers.
  - Audit GRDB `read`/`write` closures for `Sendable` safety; isolate `ClipDatabase` as needed.
  - Replace GCD background work (`DispatchQueue.global`, `asyncAfter`) with `Task`/`TaskGroup`; rework the `Subprocess` timeout and `ClipboardMonitor` polling under structured concurrency.
  - Confirm row models (`Clip`, `Category`, `ClipSearchQuery`) are `Sendable`.
  - Flip `swiftLanguageMode(.v6)` on the test target first, then the executable target. Update the `Package.swift` comment.
- Out of scope: any new feature.
- Key APIs: `@MainActor`, `@preconcurrency`, `Sendable`, `nonisolated`, `Mutex`, `OSAllocatedUnfairLock`, `MainActor.assumeIsolated`, `Task`/`TaskGroup`.
- Primary files: `Package.swift`, `HotKeyCenter`, `KeystrokeService`, `PasteService`, `CaretLocator`, `ClipboardMonitor`, `Subprocess`, `ClipDatabase`, `AppDelegate`, `StatusBarIcon`, `main.swift`.
- Verification gate: both targets build clean under `.v6` with zero strict-concurrency errors; full test suite green; manual smoke of hotkey capture, paste, clipboard monitoring, and status-bar icon behavior.
- Risks: high. Carbon/CGEvent/AX are the hardest. Mitigate by keeping the warnings-clean staging from Phase 0 and flipping the test target before the executable.
- Open dependencies to confirm: Sparkle and TOMLKit Swift 6 compatibility; both are external and may need `@preconcurrency import`.
- Effort: roughly 3 to 4 weeks if done thoroughly; the Phase 0 inventory tightens this.

## Cross-cutting practices

- Verification protocol: every phase follows research, document, implement, verify, report. No phase is called done without a build/test run and captured output. Unverifiable UI claims are stated as unverified with the exact manual steps to confirm.
- Branching: each phase lands on its own branch off the integration branch, with its own plan and its own PR or merge.
- Subagents: independent file-level work within a phase is parallelized through subagents; a separate verifier confirms each claimed fix in a fresh context.
- Docs: this roadmap and the per-phase plans live under `docs/superpowers/`. Research references stay under `docs/superpowers/research/`.

## Appendix A: Xcode 26 Coding Intelligence setup

Source: `docs/superpowers/research/2026-06-17-xcode-coding-intelligence-setup.md` (grounded in Apple DocC JSON; some exact fields flagged as verify-in-app).

1. Open Xcode > Settings, select Intelligence in the sidebar.
2. Built-in providers (shown where available):
   - ChatGPT in Xcode: under Chat, click Turn On in the ChatGPT row, then Next, then Turn On ChatGPT. Works with or without an account; sign in for higher limits.
   - Claude: under Chat, click Claude Sonnet & Opus, then Sign In (browser auth).
   - Agents: under Agents, click Get next to an agent, then Install; sign in via the More (...) button in the Account row.
3. Add a local model provider: under Chat, click Add a Chat Provider, choose Locally Hosted, enter a port and optional description, click Add. The provider must support the Chat Completions API at `{URL}/v1/models` and `{URL}/v1/chat/completions`. Ollama (port 11434, `/v1`) and LM Studio (port 1234, `/v1`) both satisfy this. For an internet gateway, choose Internet Hosted and enter the URL.
4. Use in the Coding Assistant: Command-0 (or the Coding Assistant button), New Conversation, pick an agent or model. Reference context with `@symbol`/`@file`, the Attachments pop-up, and the Project Context toggle (on by default for chat models). Agents support plan mode (`/plan`, exit `/exit-plan`).
5. Use in the source editor: open the coding tools popover via Control-click then Show Coding Tools, the gutter button, or Command-Option-0. Actions: Explain, Generate a Preview, Generate a Playground, Document, and Generate Fix for Issue on diagnostics.
6. Customize: Intelligence settings > Permissions (Allowed Commands / Allowed Tools), Plug-ins (Add Plug-in), per-agent config under `~/Library/Developer/Xcode/CodingAssistant/`.
7. Privacy: prompts may give the chosen provider access to project files; locally hosted providers keep inference on-device. The in-app "About Intelligence in Xcode & Privacy" dialog is authoritative. MDM control: set `CodingAssistantAllowExternalIntegrations` to `false` to disable external integrations.

Verify-in-app gaps: no specific macOS/Xcode version or Apple Intelligence prerequisite is stated on the doc pages (check Xcode 26 release notes); the local-provider dialog documents port plus optional description only, with the two `/v1` endpoints as the firm contract.

## Appendix B: Research references

- `docs/superpowers/research/2026-06-17-liquid-glass-symbols-hig.md`
- `docs/superpowers/research/2026-06-17-foundationmodels-swift6-observation.md`
- `docs/superpowers/research/2026-06-17-xcode-coding-intelligence-setup.md`

## Open questions to resolve during execution

1. `HotKeyCenter` isolation: confirm whether it already uses the safe `Unmanaged` + main-actor pattern (Phase 0 warning inventory settles this).
2. Sparkle and TOMLKit Swift 6 compatibility (Phase 5).
3. GRDB row-model `Sendable` conformance for `Clip`, `Category`, `ClipSearchQuery` (Phase 5).
4. Whether `NavigationSplitView` for settings is worth the change versus keeping the current `Form`, decided during Phase 2 with a quick prototype.

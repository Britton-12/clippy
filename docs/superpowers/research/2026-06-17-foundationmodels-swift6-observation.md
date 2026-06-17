# FoundationModels + Swift 6 Concurrency + Observation (macOS 26)

Research date: 2026-06-17. Grounded in Apple Developer docs (DocC JSON) and swift.org migration guide. Source URLs cited inline.

App ground truth (this repo, `Package.swift`): `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, both targets pinned to `.swiftLanguageMode(.v5)` (comment: "AppKit delegates and Carbon callbacks are simpler under the v5 concurrency model"). `HotKeyCenter.swift` uses Carbon `InstallEventHandler` + `Unmanaged` + `Task { @MainActor in }`. App uses `@State` widely but no `@Observable` on its own model types yet; an `AI/` dir + `AIEngine` exist, no FoundationModels symbols imported yet.

---

## 1. FoundationModels framework

Availability: iOS/iPadOS/macOS/visionOS/Mac Catalyst **26.0**, watchOS 27.0 (beta). On-device only, powers Apple Intelligence. https://developer.apple.com/documentation/foundationmodels

### SystemLanguageModel + availability
`final class SystemLanguageModel`. `SystemLanguageModel.default` = base general-purpose text model. https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel

Always check availability before use (it can be unavailable; model also downloads asynchronously). Two checks: `.isAvailable` (Bool) and `.availability` (enum). https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum

```swift
struct GenerativeView: View {
    private var model = SystemLanguageModel.default
    var body: some View {
        switch model.availability {
        case .available:
            // intelligence UI
        case .unavailable(.deviceNotEligible):       // device lacks Apple Intelligence
        case .unavailable(.appleIntelligenceNotEnabled): // ask user to enable in Settings
        case .unavailable(.modelNotReady):           // downloading / system busy
        case .unavailable(let other):                // unknown
        }
    }
}
```
- `@frozen enum Availability { case available; case unavailable(UnavailableReason) }`
- `enum UnavailableReason { case appleIntelligenceNotEnabled, deviceNotEligible, modelNotReady }`
- Capabilities: `contextSize: Int` (max tokens, `@backDeployed(before: 26.4)`), `supportedLanguages`, `supportsLocale(_:)`, `tokenCount(for:)`.
- Specialized model: `init(useCase:guardrails:)` with `UseCase` and `Guardrails`. `Guardrails.default` flags sensitive input/output; `.permissiveContentTransformations` relaxes for transformation tasks. https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails

### LanguageModelSession
`final class LanguageModelSession`. A single context that maintains state across requests. Reuse for multiturn; new instance per single-turn. https://developer.apple.com/documentation/foundationmodels/languagemodelsession

```swift
let session = LanguageModelSession(instructions: """
    You are a motivational workout coach that provides quotes...
    """)
let response = try await session.respond(to: "Generate a motivational quote.")
```
- Init: `init(model:tools:instructions:)`, `init(model:tools:transcript:)`. Also dynamic-profile and history variants.
- **Instructions** steer the model and outrank prompt content (model obeys instructions over prompts) - only put trusted content in instructions. Specify role, task, style, safety. https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
- One request at a time per session: calling again before completion is a **runtime error**. Guard with `isResponding: Bool`.
- `prewarm(promptPrefix:)` eagerly loads model into memory (call when you have >=1s warning, e.g. user starts typing). https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:)
- `usage` / `Usage` for token accounting; full `Transcript` of prompts+responses.

### respond(to:)
`@discardableResult nonisolated(nonsending) final func respond(to prompt: Prompt, options: GenerationOptions = .init()) async throws -> LanguageModelSession.Response<String>`. Async (seconds of latency). https://developer.apple.com/documentation/foundationmodels/languagemodelsession/respond(to:options:)

Structured: `respond(to:generating:)` returns your `Generable` type:
```swift
let r = try await session.respond(to: "How many tbsp in a cup?", generating: Float.self)
let cat = try await session.respond(to: "Generate a cute rescue cat", generating: CatProfile.self)
```

### streamResponse(to:) - streaming
`final func streamResponse(to prompt: Prompt, options: ...) -> sending LanguageModelSession.ResponseStream<String>`. https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:)

`struct ResponseStream<Content: Generable>` is an **async sequence of snapshots of partially generated content** (each element is a growing `Content.PartiallyGenerated` / `Snapshot`, not a delta). `.collect()` to await the final value.
```swift
let stream = session.streamResponse(to: prompt, generating: CatProfile.self)
for try await partial in stream {   // partial is PartiallyGenerated; bind to UI
    self.draft = partial
}
```
- `streamResponse(to:generating:includeSchemaInPrompt:options:)` for `Generable Content`; `includeSchemaInPrompt` defaults `true` (set false only if model already knows the format). https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:generating:includeschemainprompt:options:)
- **Background guidance**: if running in the background, prefer the non-streaming `respond` to reduce `exceededContextWindowSize` errors.

### @Generable / @Guide - structured output
`protocol Generable : ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent`. Uses **constrained sampling** so output is guaranteed to match the type (no manual string parsing, no malformed output). https://developer.apple.com/documentation/foundationmodels/generable

```swift
@Generable(description: "Basic profile information about a cat")
struct CatProfile {
    var name: String                                   // guide optional for basic fields
    @Guide(description: "The age of the cat", .range(0...20)) var age: Int
    @Guide(description: "A one sentence profile") var profile: String
}
```
- `@Generable` on struct/enum/actor; `@Guide` only on stored properties. Supports `Bool/Int/Float/Double/Decimal/Array` and nesting; enums with associated values allowed.
- Guides: `.count(_)`, `.range(_)`, `GenerationGuide`; `GenerationID` for framework-generated items.
- Properties generated **in declaration order**. Long descriptions cost context/latency - keep short.
- Dynamic schema at runtime: `DynamicGenerationSchema` + `GenerationSchema(root:dependencies:)`, then `respond(to:schema:)`. https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation

### Tool protocol - tool calling
`protocol Tool<Arguments, Output> : Sendable`. Lets the model call your code at runtime (fresh data, side effects). https://developer.apple.com/documentation/foundationmodels/tool

```swift
struct FindContacts: Tool {
    let name = "findContacts"
    let description = "Finds a specific number of contacts"
    @Generable struct Arguments {
        @Guide(description: "The number of contacts", .range(1...10)) let count: Int
    }
    func call(arguments: Arguments) async throws -> [String] { /* ... */ }
}
```
- Required: `name`, `description` (both injected into prompt so the model decides when/how often to call), `Arguments` (`Generable`), `func call(arguments:) async throws -> Output` (Output `String` or `PromptRepresentable`).
- Must be `Sendable` (framework runs tools concurrently). You own tool lifecycle/state between calls. Model can chain back-to-back tool calls.

### Context window, errors, privacy
- **Context window = 4,096 tokens** total per session (instructions + all prompts + all outputs + tool defs + schemas all count). ~3-4 chars/token (en/es/de), ~1 token/char (ja/zh/ko). https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
- Overflow throws `LanguageModelSession.GenerationError.exceededContextWindowSize`. Recovery: drop transcript entries and retry, or chunk data across separate sessions and combine. `contextSize` property reports the runtime max.
- Full error set (`GenerationError`): `assetsUnavailable`, `decodingFailure`, `exceededContextWindowSize`, `guardrailViolation`, `rateLimited`, `refusal`, `concurrentRequests`, `unsupportedGuide`, `unsupportedLanguageOrLocale`. https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror
- `GenerationOptions(samplingMode:temperature:maximumResponseTokens:toolCallingMode:)` - `temperature` for creativity; only set `maximumResponseTokens` to cap verbosity (it can produce malformed/ungrammatical output). https://developer.apple.com/documentation/foundationmodels/generationoptions

### What it can / cannot do vs a cloud LLM
- CAN: on-device text generation/understanding, summarization, classification, extraction, guided/structured output, tool calling, multiturn within one small context. Fully private, offline, no API cost.
- CANNOT: no built-in web/search access (you must supply data via tools); tiny 4,096-token context (vs 100K+ cloud); not for tasks needing extensive world knowledge or long-document reasoning; quality below frontier cloud models; requires Apple-Intelligence-capable hardware with the feature enabled.

---

## 2. Swift 6 strict-concurrency migration (from Swift 5 mode)

Swift 6 language mode makes the compiler **guarantee data-race-free** code; previously-optional checks become required. Opt-in, **per target**. Compiler supports modes "6", "5", "4.2", "4". https://www.swift.org/migration/documentation/migrationguide/

### Enable per target
SPM (`swift-tools-version: 6.0`+ defaults all targets to mode 6; override per target): https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety
```swift
.target(name: "FullyMigrated"),                          // default = mode 6
.target(name: "NotQuiteReadyYet",
        swiftSettings: [.swiftLanguageMode(.v5)])         // pin a target to v5
```
- Xcode: build setting "Swift Language Version" = 6, or `SWIFT_VERSION = 6` in xcconfig.
- CLI: `swift build -Xswiftc -swift-version -Xswiftc 6`.

### Upcoming-feature flags (do this BEFORE flipping to mode 6)
Surface issues as **warnings** while staying in v5 - keeps build/tests green. Enable complete checking via `-strict-concurrency=complete`:
- SPM, Swift 5.9/5.10 tools: `swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]`
- SPM, Swift 6.0+ tools (pre-6 target): `swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]`
- Xcode: "Strict Concurrency Checking" = Complete, or `SWIFT_STRICT_CONCURRENCY = complete` in xcconfig.
- CLI: `swift build -Xswiftc -strict-concurrency=complete`.
Enable upcoming concurrency feature flags one at a time (independent, any order) to tackle one class of problem before complete checking. https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy

### Practical migration order
1. Start at the **outermost root module** (no other module depends on it - changes stay local). Or fix a dependency you own that other modules import.
2. Enable Swift 5 + one upcoming flag, then `-strict-concurrency=complete` (warnings only).
3. **Address warnings with minimal change** - resist refactoring; reach warning-free, then revisit unsafe opt-outs as follow-on refactors.
4. Iterate inward to dependencies. Then flip the module to mode 6.

### Sendable conformance strategies (four ways)
https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems
- **Global isolation**: `@MainActor struct X {}` -> implicitly `Sendable`.
- **Actor**: gets implicit `Sendable` + own isolation domain; methods become `async`.
- **Checked class `Sendable`**: must be `final`, not inherit (except `NSObject`), no non-isolated mutable stored props: `final class Style: Sendable { let bg: ColorComponents }`.
- **Manual sync**: `class Style: @unchecked Sendable {}` when you guard with a lock/queue yourself. Retroactive on a dependency type: `extension X: @retroactive @unchecked Sendable {}` (use sparingly).
- Composition allowed: one prop `nonisolated(unsafe) var` (lock-guarded), another `@MainActor var`, in the same `final ... : Sendable` class.
- Public value types are NOT implicitly `Sendable` - declare it. Non-public ones are inferred.
- `sending` parameter lets a non-`Sendable` value cross a boundary when the compiler can prove safety; `@Sendable () -> T` closure to compute the value on the far side.

### Global/static mutable state
`var supportedStyleCount = 42` -> error (non-isolated global mutable). Fixes: make it `let`, computed `var { 42 }`, `@MainActor var`, or - if externally synchronized - `nonisolated(unsafe) var` (only with a lock/queue around all access).

### AppKit delegates + protocol isolation mismatch (the main friction for this app)
A `@MainActor` class satisfying a non-isolated synchronous protocol requirement errors: "main actor-isolated method cannot be used to satisfy nonisolated protocol requirement." Solutions:
- Isolate the **protocol** to `@MainActor` (whole protocol or per-requirement `@MainActor func`). Most AppKit delegate methods are main-thread.
- `@preconcurrency @MainActor protocol` to stay source-compatible with un-migrated clients; or `class C: @preconcurrency Proto {}` (inserts runtime checks).
- Make the requirement `async` (an isolated sync method can satisfy a non-isolated `async` requirement) - but this changes every call site.
- `nonisolated func` on the conforming method if it touches no `@MainActor` state.
- ObjC/SDK side: annotate with `NS_SWIFT_UI_ACTOR` (== `@MainActor`), `NS_SWIFT_SENDABLE`, `NS_SWIFT_NONISOLATED`, etc. (Clang `swift_attr`). https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption

### @convention(c) / Carbon callbacks (e.g. `HotKeyCenter.swift`)
The guide does not cover `@convention(c)` directly, but the established pattern (already used in this repo's `HotKeyCenter`): a C function pointer cannot capture context, so pass `self` via `Unmanaged.passUnretained(self).toOpaque()`, recover it with `Unmanaged<T>.fromOpaque(userData).takeUnretainedValue()` inside the callback, then hop to the main actor with `Task { @MainActor in ... }` (or `MainActor.assumeIsolated`). Under mode 6 the callback body is non-isolated; any state it touches must be `Sendable` or reached via an actor hop. Keep these in a v5 target if the hop pattern is awkward.

### Dynamic isolation escape hatches
- `MainActor.assumeIsolated { }` - **synchronous**, asserts "I'm already on the main actor's executor or crash"; recovers isolation from runtime into the type system. Use in sync callbacks known to run on main. https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)
- `await MainActor.run { }` - async hop; useful during migration but not a substitute for static `@MainActor`.
- `@preconcurrency import UnmigratedModule` - downgrades cross-isolation errors to warnings until the dependency is updated.
- `-disable-dynamic-actor-isolation` - suppresses runtime isolation assertions (caution: permits violations).

### Locks for guarded mutable state
- `Mutex<Value>` (Synchronization, **macOS 15+**): `let cache = Mutex<[K:V]>([:])`; `cache.withLock { $0[k] = v }`. Value type, `~Copyable`. https://developer.apple.com/documentation/synchronization/mutex
- `OSAllocatedUnfairLock<State>` (os, **macOS 13+**): use instead of raw `os_unfair_lock` (which is unsafe in Swift - value type without a stable address). https://developer.apple.com/documentation/os/osallocatedunfairlock

### Other friction
- Wrap callback APIs with `withCheckedContinuation` (resume exactly once). https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption
- Actor-isolated `init` called from non-isolated default-value/static context errors -> make `init` `nonisolated` (Sendable props still initializable).
- `@Sendable` closures do NOT infer actor isolation - hop explicitly inside.
- Actors can use a `DispatchSerialQueue` as `unownedExecutor` to interop with existing GCD code.

---

## 3. Observation framework

`@Observable` macro (Observation), SwiftUI support since macOS 14 / iOS 17. Implements `Observable` conformance at compile time; type-safe observer pattern. https://developer.apple.com/documentation/observation

```swift
@Observable
class Car { var name = ""; var needsRepairs = false }
```

### @Observable vs ObservableObject - benefits
https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro
- Tracks optionals and collections of objects (impossible with `ObservableObject`).
- Uses plain `@State` / `@Bindable` instead of `@StateObject` / `@ObservedObject` / `@Published`.
- **Per-property view updates**: SwiftUI re-renders a view only when a property the view's `body` actually reads changes. `ObservableObject` re-renders on ANY `@Published` change even if `body` ignores it. Performance win.

### Migration steps
1. Replace `: ObservableObject` with `@Observable` macro on the model class.
2. Remove `@Published` from properties (no wrapper needed; observability follows accessibility to the observer).
3. Apply `@ObservationIgnored` to stored properties you do NOT want tracked.
4. In views: `@StateObject` -> `@State`; `@ObservedObject` -> drop it (SwiftUI auto-tracks what `body` reads); `@EnvironmentObject` -> `@Environment`; `.environmentObject(x)` -> `.environment(x)`.
5. For two-way bindings to an observable type, use `@Bindable` (replaces the binding role `@ObservedObject` played).
```swift
// BEFORE
@StateObject private var library = Library()
.environmentObject(library)
// AFTER
@State private var library = Library()
.environment(library)
```

### Incremental + gotchas
- Migrate one model type at a time; `@Observable` and `ObservableObject` types coexist. `@State`/`@Environment` accept `@Observable` types, so you can convert the model before the view plumbing.
- `withObservationTracking(_:onChange:)` tracks only properties read inside the `apply` closure; the `onChange` fires once on the next mutation of a tracked property.
- **Computed properties**: a computed property is observable only insofar as it reads tracked stored properties inside its getter; if it reads `@ObservationIgnored` or external state, changes will not trigger view updates.
- `@ObservationIgnored` opts a stored property out of tracking (use for caches, derived state, non-UI fields).
- Behavioral diff vs `ObservableObject`: views update more narrowly under `@Observable` - watch for views that previously re-rendered on unrelated `@Published` changes and relied on it.

### Interaction with @MainActor (Swift 6 relevance)
- Apple's own samples mark observable models `@Observable @MainActor final class Model { }` so UI state stays main-isolated and gains implicit `Sendable`. With `[.macOS(.v26)]` this is the natural pattern.
- A non-isolated `@Observable` class touched from background tasks needs its mutations hopped to the main actor; isolating the whole model to `@MainActor` removes that class of warning under strict concurrency.
- For this repo: model classes currently use `@State` value props in views and no `@Observable` model classes yet. New shared model state should be `@Observable @MainActor` and injected with `.environment(...)`/`@Environment`.

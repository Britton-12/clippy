# AI Assistant Chat Rewrite - Design

Date: 2026-06-15
Branch: feature/ai-chat-rewrite
Status: Approved, pending implementation plan

## Problem

The AI assistant chat (`Sources/Clippy/AI/AIAssistantPanelView.swift`) has three defects, two critical:

1. **App freeze on a second message.** Tool confirmation uses `withCheckedContinuation` (`:128-135`) resolved only by the sheet's Allow/Deny buttons (`:137-141`, `:177-183`). Any other dismissal (Escape, click-away), or the `.sheet` failing to present from the borderless `.nonactivatingPanel`, leaves the continuation unresolved. The `send()` Task then hangs, `state` stays `.thinking` forever, the send button stays disabled, and the app appears frozen. There is no timeout, no cancellation, and no Stop control, so any wedged network call produces the same lockup.
2. **No streaming.** `AIAgent.completeWithTools` runs the whole agent loop and returns one final `String`; the bubble text is assigned once (`:108`). The user stares at an empty "thinking" bubble until everything (including tool calls) finishes.
3. **Raw markdown rendering.** Assistant text renders via plain `Text(message.text)` (`:413`). Literal markdown (`**`, `#`, fenced ``` ``` ```) shows with no formatting and no code blocks. There is no markdown layer.

Multi-turn conversation already works: `buildHistory()` sends full prior history every turn. The perception of "no real chat" comes from defects 2 and 3 plus the freeze.

## Goals

- Token streaming for the chat across all four providers (Ollama, Anthropic, OpenAI, Azure OpenAI).
- Markdown rendering with real fenced code blocks via the MarkdownUI SPM package.
- A chat lifecycle that cannot freeze: single-resume confirmation, guaranteed `state` reset, overall + idle timeouts, cancellation via a Stop button.

## Non-Goals

- No change to the one-shot `complete` / `completeWithTools` path. It stays for non-chat AI actions (title generation, rewrite, etc.). Streaming is added alongside, not in place of it.
- No change to the tool system, settings, keychain, provider config, the provider factory, or `AIService.fromSettings()` validation.
- No conversation persistence across panel close (still out of scope, as today).
- No syntax-highlighting engine beyond what MarkdownUI provides out of the box.

## Existing Architecture (grounding)

- **Provider protocol:** `AIAgentProvider: AIProvider` with `completeWithTools(_:tools:options:) async throws -> AIAgentTurn` (`AIAgent.swift:14-22`); parent `AIProvider.complete(_:options:)` (`AIProvider.swift:44-46`).
- **Turn/tool types:** `AIAgentTurn { .text(String), .toolCalls([AIToolCall]) }` (`AIAgent.swift:26-29`); `AIToolCall { id, toolName, arguments:[String:Any] }` (`:31-42`).
- **Agent loop:** `AIAgent.completeWithTools(messages:provider:tools:options:)` (`AIAgent.swift:63-116`), max 8 rounds, appends tool results via `AIToolResultSentinel.encode` (`:141-162`).
- **Providers (all one-shot via `AIHTTP.post`):** OpenAI (`:172-249`), Anthropic (`:259-358`, groups tool_results into one user message), Ollama (`:369-445`, `"stream": false` at `:398`), Azure (`:452-484`, reuses OpenAI wire/parse). Factory `AIAgentProviderFactory.make(kind:config:)` (`:488-497`).
- **Transport:** `AIHTTP.post` (`AIProviders.swift:15-56`) uses `URLSession.shared.data(for:)`, 60s `timeoutInterval`, no streaming.
- **Shared types:** `AIMessage {role:AIRole, content:String}` (`AIProvider.swift:11-14`), `AIRole {system,user,assistant}` (`:5-9`), `AICompletionOptions {temperature=0.3, maxTokens=1024}` (`:16-19`), `AIProviderConfig {baseURL,apiKey,model,apiVersion}` (`AIProviders.swift:5-11`), `AITool` protocol (`AIToolDefinition.swift:12-18`), tool specs `openAIFunctionSpec`/`anthropicToolSpec` (`:23-42`).
- **Tools:** `AIToolRegistry.makeFiltered(allowScripts:allowCodeExecution:confirmHook:)` (`AIToolDefinition.swift:302-318`); gated tools (`RunScriptTool`, `ExecuteCodeTool`) await `confirmHook(prompt) async -> Bool`.
- **UI:** `AIAssistantViewModel` (`@MainActor ObservableObject`, `:28-153`) with `send()`, `askConfirmation`, `resolveConfirmation`, `buildHistory`, `clearConversation`. `AIAssistantPanelView` (`:157-`) with `header`, `content` (empty state + suggestions + `MessageBubble` thread), `inputBar`, and the `.sheet` confirmation. `ToolConfirmationSheet` (`:461-504`).
- **Hosting:** instantiated in `ClipListView.swift:236-237` when `selection == .assistant`, inside the borderless `.nonactivatingPanel` (`PanelController.swift:148-153`).
- **Provider kinds & settings:** `AIProviderKind {ollama, openai, anthropic, azureFoundry}` (`AIProvider.swift:49-99`) with `defaultBaseURL`, `defaultModel`, `needsAPIKey`, `keychainAccount`. AI settings in `AppSettings.swift` (`aiEnabled, aiProvider, aiModel, aiBaseURL, aiAzureAPIVersion, aiAgentAllowScripts, aiAgentAllowCodeExecution`).
- **Build:** `Package.swift` swift-tools 6.0, platform `.macOS(.v14)` (MarkdownUI-compatible). Deps: GRDB 7, Sparkle 2.9.3, TOMLKit 0.6.

## Design

### A. MarkdownUI dependency
Add `https://github.com/gonzalezreal/swift-markdown-ui` (product `MarkdownUI`) to `Package.swift` dependencies and the `Clippy` target. Pin a version known to support macOS 14 (resolve and confirm via `swift build`).

### B. Streaming transport - `AIStreamingHTTP`
New helper (in `Sources/Clippy/AI/`) exposing:
```swift
enum AIStreamingHTTP {
    /// POSTs `body` and yields each response line as it arrives.
    static func postLines(url: String, headers: [String: String], body: [String: Any],
                          overallTimeout: TimeInterval = 120,
                          idleTimeout: TimeInterval = 30) -> AsyncThrowingStream<String, Error>
}
```
Uses `URLSession.bytes(for:)` and iterates `.lines`. Enforces an overall deadline and an idle (no-bytes) timeout via a watchdog `Task`; on timeout it cancels the URLSession task and finishes the stream with `AIError`. Non-2xx status throws `AIError.http`.

### C. Provider streaming - `AIAgentProvider.streamWithTools`
Add to the protocol:
```swift
func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                     options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error>
```
Shared event type:
```swift
enum AIStreamEvent { case textDelta(String); case toolCalls([AIToolCall]); case done }
```
Each provider sets `"stream": true`, reuses its existing `wireMessages` and tool specs, calls `AIStreamingHTTP.postLines`, and parses its wire format into events. Parsing is factored into a pure function per provider (`parseStreamLine`/accumulator) so it is independently testable:
- **OpenAI / Azure:** SSE. Lines `data: {json}`; ignore `data: [DONE]`. Accumulate `choices[0].delta.content` -> `.textDelta`. Accumulate `choices[0].delta.tool_calls[]` fragments by `index` (id, function.name, function.arguments string pieces). On `finish_reason == "tool_calls"` emit `.toolCalls(assembled)`; otherwise the accumulated text is the turn. End with `.done`.
- **Anthropic:** SSE. Events: `content_block_start` (text or `tool_use` with id/name), `content_block_delta` (`text_delta.text` -> `.textDelta`; `input_json_delta.partial_json` -> accumulate per block), `content_block_stop`, `message_delta` (`stop_reason`), `message_stop`. On `stop_reason == "tool_use"` parse accumulated input JSON per tool_use block -> `.toolCalls`. End with `.done`.
- **Ollama:** JSONL. Each line `{message:{content, tool_calls?}, done}`. `message.content` -> `.textDelta`. The final `done == true` line's `message.tool_calls` (if any) -> `.toolCalls`. End with `.done`.

Malformed JSON in a line is skipped (logged), never fatal. If a tool-call's arguments fail to parse at stream end, the turn surfaces an `AIError` rather than hanging.

### D. Streaming agent loop - `AIAgent.streamWithTools`
```swift
enum AIAgentEvent { case textDelta(String); case toolStarted(String); case toolFinished(String) }

static func streamWithTools(messages:[AIMessage], provider:AIAgentProvider, tools:[AITool],
                            options:AICompletionOptions = .init())
    -> AsyncThrowingStream<AIAgentEvent, Error>
```
Same control flow as `completeWithTools` (max 8 rounds, sentinel-encoded tool results appended to a mutable history), but:
- For each round, consume `provider.streamWithTools(...)`. Forward `.textDelta` as `.textDelta`. Collect any `.toolCalls`.
- If the round produced tool calls: append the assistant tool-call history message, then for each call emit `.toolStarted(name)`, execute the tool (await; `confirmHook` unchanged), append the sentinel result, emit `.toolFinished(name)`. Loop to the next round.
- If the round produced only text: finish the stream.
- Round cap behavior preserved (final summary turn if exhausted), streamed.

### E. View model rewrite (freeze elimination)
Rewrite `AIAssistantViewModel`:
- `enum State { case ready, streaming, notConfigured(String) }`.
- `private var runningTask: Task<Void, Never>?`. `func stop()` cancels it.
- `send()` builds provider/registry as today, appends the user message and an empty assistant message, sets `.streaming`, and starts `runningTask`:
  ```swift
  runningTask = Task { [weak self] in
      defer { self?.state = .ready; self?.runningTask = nil }   // ALWAYS resets
      do {
          for try await event in AIAgent.streamWithTools(...) {
              if Task.isCancelled { break }
              // append textDelta to messages[idx].text (coalesced); toolStarted/Finished -> toolActivities
          }
      } catch is CancellationError {
          // leave partial text; mark not an error
      } catch {
          messages[idx].text = error.localizedDescription; messages[idx].isError = true
      }
  }
  ```
  `defer` guarantees the freeze class cannot recur: success, error, cancel, or timeout all reset `state`.
- Text-delta coalescing: buffer deltas and flush to the published `messages[idx].text` at most ~20 times/sec (a small accumulator + timer/`Task.sleep`) so MarkdownUI re-parse stays cheap during fast streams.
- **Confirmation rewrite:** replace the `.sheet` with an inline confirmation card rendered as an overlay inside the panel (the `.nonactivatingPanel` makes sheets unreliable). State `@Published var pendingConfirmation: PendingConfirmation?` drives the overlay. `resolve(_ allowed: Bool)` is idempotent (nils the continuation before/while resuming, so a double-tap or a dismiss-after-resolve can't double-resume or leak). A dismiss/cancel path resolves `false`. The continuation is guaranteed to resume exactly once.

### F. Input bar + Stop
While `.streaming`, the send button becomes a **Stop** button (square icon) that calls `vm.stop()`. Input remains editable; submitting while streaming is ignored (or queued - out of scope, so ignored). When `.ready`, it's the send arrow as today.

### G. Rendering (MessageBubble)
Assistant, non-error bubbles render with MarkdownUI:
```swift
Markdown(message.text.isEmpty ? " " : message.text)
    .markdownTheme(.clippy(tokens: tokens, settings: settings))   // custom theme
    .textSelection(.enabled)
```
A custom `Theme` maps to Clippy tokens: body font/color from `PanelTypography`/`tokens.textPrimary`; fenced code blocks in monospace on `tokens.cardSurface` with a border and horizontal scroll; inline code tinted; lists/links styled. User bubbles keep plain `Text` (user input is not markdown). Error bubbles keep the existing orange `Label`.

## Verification

No XCTest here (Command Line Tools only). Gate on:
- `swift build` resolves MarkdownUI and ends with `Build complete!`.
- Per-provider stream parsers are pure functions; verify with small inline `main`-level checks or DEFERRED XCTest cases (one per provider) feeding canned SSE/JSONL fixtures and asserting the emitted events.
- Manual chat run against the user's real configuration:
  - First and SECOND (and third+) messages all stream and complete; no freeze.
  - Assistant markdown renders with formatted code blocks.
  - A tool-using turn shows "Running X..." then "Ran X"; the inline confirmation card appears, and Allow / Deny / dismiss all resume cleanly with state returning to ready.
  - Stop button cancels mid-stream and the chat returns to ready (can send again).
  - A provider/network error shows an error bubble and resets to ready (no lockup).

## Risks / Open Questions

- **Streaming tool-call assembly** (OpenAI fragment accumulation; Anthropic partial-JSON) is the highest-risk parsing work. Mitigation: pure per-provider parser functions with canned-fixture checks; malformed input degrades to an error, never a hang.
- **MarkdownUI version pinning** for macOS 14: confirm the chosen version resolves and builds; adjust the pin if needed.
- **Streaming + tools interleaving:** providers may emit some text before a tool call in one turn. The loop forwards that text, then runs tools, then continues - acceptable. Heavy mid-text tool interleaving is not specially handled beyond per-round accumulation.
- **Inline confirmation overlay** must visually sit above the message thread and trap focus for its buttons within the panel; verify in a manual run.

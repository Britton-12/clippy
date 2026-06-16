# AI Assistant Chat Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the AI assistant chat with token streaming across all four providers, MarkdownUI rendering (real code blocks), and a lifecycle that cannot freeze - on branch `feature/ai-chat-rewrite`.

**Architecture:** Add a streaming path alongside the untouched one-shot engine. A new `AIStreamingHTTP` reads response bytes as lines; each provider gains a `streamWithTools` returning `AsyncThrowingStream<AIStreamEvent,Error>`; a new `AIAgent.streamWithTools` runs the same agent loop but forwards text deltas and tool start/finish events. The view model consumes that stream with a `defer`-guaranteed state reset, a Stop button, timeouts, and an inline (non-sheet) confirmation card. `MessageBubble` renders assistant text with MarkdownUI.

**Tech Stack:** Swift 6 (language mode v5), SwiftUI + AppKit (borderless NSPanel), URLSession streaming (`bytes(for:)`), SPM, MarkdownUI. Build gate: `swift build`. No XCTest in this environment.

---

## Verification model (read first)

The XCTest target does not compile without Xcode.app, which is not installed here. So:
- Compile gate every task: `swift build` ending in `Build complete!`.
- Behavior gate: a manual chat run (the controller/user does this) against a real provider, because subagents have no GUI.
- Pure parser functions (per-provider stream parsing) get **DEFERRED TEST** notes - add XCTest cases for the next Xcode-equipped run, but verify here by reasoning + build.

Commit after each task. Small commits.

## File map

**Create:**
- `Sources/Clippy/AI/AIStreaming.swift` - `AIStreamEvent`, `AIAgentEvent`, `AIStreamingHTTP` (lines transport with timeouts).
- `Sources/Clippy/AI/MarkdownTheme.swift` - MarkdownUI `Theme.clippy(tokens:settings:)`.

**Modify:**
- `Package.swift` - add MarkdownUI dependency + target dep.
- `Sources/Clippy/AI/AIAgent.swift` - add `streamWithTools` to the protocol, each provider, and the agent loop.
- `Sources/Clippy/AI/AIAssistantPanelView.swift` - rewrite the view model (streaming, stop, timeouts, inline confirmation) and the views (MessageBubble markdown, input bar Stop, inline confirmation overlay). Remove the `.sheet`.

**Unchanged (reused):** `AIProvider.swift`, `AIProviders.swift` (one-shot `AIHTTP.post` stays), `AIToolDefinition.swift`, settings, keychain.

---

## Task 1: Add MarkdownUI dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the package and target dependency**

In `Package.swift`, add to the `dependencies` array (after the TOMLKit `.package` line):
```swift
.package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
```
And to the `Clippy` target's `dependencies` array (after the TOMLKit `.product` line):
```swift
.product(name: "MarkdownUI", package: "swift-markdown-ui"),
```
Match the exact array indentation already in the file (read it first).

Note on version: `2.4.0` targets macOS 12+ and works on the macOS 14 deployment target. If resolution fails, try `from: "2.0.0"`. Report the version that actually resolves.

- [ ] **Step 2: Resolve and build**

Run: `swift build`
Expected: SPM resolves `swift-markdown-ui` (you'll see it fetched) and ends with `Build complete!`. If it fails to resolve, adjust the version floor and retry; record what worked.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add MarkdownUI dependency"
```
(Include `Package.resolved` if it exists/updates.)

## Task 2: Streaming event types and transport

**Files:**
- Create: `Sources/Clippy/AI/AIStreaming.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// One low-level event from a provider's streamed response.
enum AIStreamEvent {
    case textDelta(String)
    case toolCalls([AIToolCall])
    case done
}

/// One high-level event from the streaming agent loop, consumed by the UI.
enum AIAgentEvent {
    case textDelta(String)
    case toolStarted(String)
    case toolFinished(String)
}

/// Streaming HTTP: POST a JSON body and yield each response line as it arrives,
/// with an overall deadline and an idle (no-bytes) timeout so a wedged
/// connection cannot hang the caller forever.
enum AIStreamingHTTP {
    static func postLines(
        url urlString: String,
        headers: [String: String],
        body: [String: Any],
        overallTimeout: TimeInterval = 120,
        idleTimeout: TimeInterval = 30
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                guard let url = URL(string: urlString) else {
                    continuation.finish(throwing: AIError.badURL(urlString)); return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = overallTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: error); return
                }

                // Idle watchdog: bumped on every line; cancels the read if it stalls.
                let lastActivity = ActivityClock()
                let watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if lastActivity.secondsSince() > idleTimeout {
                            continuation.finish(throwing: AIError.http(-1, "stream idle timeout"))
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        // Drain a little body for the error message.
                        var errText = ""
                        for try await line in bytes.lines { errText += line; if errText.count > 2000 { break } }
                        continuation.finish(throwing: AIError.http(http.statusCode, errText)); return
                    }
                    for try await line in bytes.lines {
                        lastActivity.bump()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// Tiny monotonic activity marker for the idle watchdog.
final class ActivityClock: @unchecked Sendable {
    private var last = Date()
    private let lock = NSLock()
    func bump() { lock.lock(); last = Date(); lock.unlock() }
    func secondsSince() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}
```

Before building: confirm `AIError` has cases `badURL(String)` and `http(Int, String)` (grep `enum AIError` - the one-shot `AIHTTP.post` already throws `AIError.badURL` and `AIError.http`, so they exist). If `AIError` is defined where this file can see it (same module), no import needed beyond Foundation. `AIToolCall` is defined in `AIAgent.swift` (same module) - no import needed.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Clippy/AI/AIStreaming.swift
git commit -m "feat(ai): streaming event types and line transport with timeouts"
```

## Task 3: Per-provider stream parsing - pure functions

**Files:**
- Modify: `Sources/Clippy/AI/AIAgent.swift`

This task adds ONLY the pure parser/accumulator helpers (no protocol/loop wiring yet) so each is isolated and reviewable.

- [ ] **Step 1: Add an OpenAI/Azure SSE stream accumulator**

Add to `OpenAIAgentProvider` (a nested type or static helpers). It must accumulate across `data:` lines:
```swift
/// Accumulates OpenAI/Azure chat-completions SSE deltas into events.
struct OpenAIStreamAccumulator {
    private var toolFragments: [Int: (id: String, name: String, args: String)] = [:]
    private var sawToolCalls = false

    /// Feed one raw SSE line. Returns text deltas to emit immediately.
    /// Tool calls are buffered until `finish()`.
    mutating func consume(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            sawToolCalls = true
            for tc in calls {
                let idx = tc["index"] as? Int ?? 0
                var entry = toolFragments[idx] ?? (id: "", name: "", args: "")
                if let id = tc["id"] as? String { entry.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let n = fn["name"] as? String { entry.name = n }
                    if let a = fn["arguments"] as? String { entry.args += a }
                }
                toolFragments[idx] = entry
            }
        }
        if let content = delta["content"] as? String, !content.isEmpty { return content }
        return nil
    }

    /// Assemble buffered tool calls (empty if the turn was plain text).
    func finishToolCalls() -> [AIToolCall] {
        guard sawToolCalls else { return [] }
        return toolFragments.sorted { $0.key < $1.key }.compactMap { _, frag in
            guard !frag.name.isEmpty else { return nil }
            let args = (frag.args.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            return AIToolCall(id: frag.id.isEmpty ? "openai-\(frag.name)" : frag.id,
                              toolName: frag.name, arguments: args)
        }
    }
}
```

- [ ] **Step 2: Add an Anthropic SSE stream accumulator**

Add to `AnthropicAgentProvider`:
```swift
/// Accumulates Anthropic Messages SSE events into text deltas + tool calls.
struct AnthropicStreamAccumulator {
    private var blocks: [Int: (type: String, id: String, name: String, json: String)] = [:]
    private var stopReason = ""

    /// Anthropic SSE arrives as paired "event:" and "data:" lines; we parse the
    /// "data:" JSON which contains a "type" field, so the event line is optional.
    mutating func consume(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return nil }
        switch type {
        case "content_block_start":
            let idx = root["index"] as? Int ?? 0
            if let block = root["content_block"] as? [String: Any] {
                let t = block["type"] as? String ?? ""
                blocks[idx] = (type: t, id: block["id"] as? String ?? "",
                               name: block["name"] as? String ?? "", json: "")
            }
        case "content_block_delta":
            let idx = root["index"] as? Int ?? 0
            if let delta = root["delta"] as? [String: Any] {
                if let t = delta["text"] as? String, (delta["type"] as? String) == "text_delta" {
                    return t
                }
                if let pj = delta["partial_json"] as? String,
                   (delta["type"] as? String) == "input_json_delta" {
                    blocks[idx]?.json += pj
                }
            }
        case "message_delta":
            if let d = root["delta"] as? [String: Any], let sr = d["stop_reason"] as? String {
                stopReason = sr
            }
        default:
            break
        }
        return nil
    }

    func finishToolCalls() -> [AIToolCall] {
        guard stopReason == "tool_use" else { return [] }
        return blocks.sorted { $0.key < $1.key }.compactMap { _, b in
            guard b.type == "tool_use" else { return nil }
            let args = (b.json.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            return AIToolCall(id: b.id, toolName: b.name, arguments: args)
        }
    }
}
```

- [ ] **Step 3: Add an Ollama JSONL stream accumulator**

Add to `OllamaAgentProvider`:
```swift
/// Accumulates Ollama /api/chat JSONL lines into text deltas + tool calls.
struct OllamaStreamAccumulator {
    private var pendingToolCalls: [AIToolCall] = []

    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            var idx = 0
            pendingToolCalls = calls.compactMap { tc in
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                let args: [String: Any]
                if let d = fn["arguments"] as? [String: Any] { args = d }
                else if let s = fn["arguments"] as? String,
                        let dd = s.data(using: .utf8),
                        let d = try? JSONSerialization.jsonObject(with: dd) as? [String: Any] { args = d }
                else { args = [:] }
                idx += 1
                return AIToolCall(id: "ollama-\(idx)", toolName: name, arguments: args)
            }
        }
        if let content = message["content"] as? String, !content.isEmpty { return content }
        return nil
    }

    func finishToolCalls() -> [AIToolCall] { pendingToolCalls }
}
```

**DEFERRED TEST:** add `AIStreamParsingTests` with canned fixtures: an OpenAI SSE tool-call fragment sequence, an Anthropic `input_json_delta` sequence, and an Ollama JSONL final-line tool call - asserting `consume`/`finishToolCalls` outputs.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` (the accumulators are unused for now; they must compile).

- [ ] **Step 5: Commit**

```bash
git add Sources/Clippy/AI/AIAgent.swift
git commit -m "feat(ai): per-provider streaming parsers (OpenAI/Anthropic/Ollama)"
```

## Task 4: Provider `streamWithTools` methods

**Files:**
- Modify: `Sources/Clippy/AI/AIAgent.swift`

- [ ] **Step 1: Add the protocol method**

In the `AIAgentProvider` protocol (`:14-22`) add:
```swift
func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                     options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error>
```

- [ ] **Step 2: Implement for OpenAI**

In `OpenAIAgentProvider`:
```swift
func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                     options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let body: [String: Any] = [
        "model": config.model,
        "messages": Self.wireMessages(messages),
        "tools": tools.map(\.openAIFunctionSpec),
        "temperature": options.temperature,
        "max_tokens": options.maxTokens,
        "stream": true,
    ]
    let lines = AIStreamingHTTP.postLines(
        url: "\(config.baseURL)/v1/chat/completions",
        headers: ["Authorization": "Bearer \(config.apiKey)"],
        body: body)
    return Self.eventStream(from: lines, accumulator: OpenAIStreamAccumulator())
}

/// Shared driver: feed lines through an accumulator, emit text deltas live,
/// emit tool calls (if any) then `.done` at end.
static func eventStream(from lines: AsyncThrowingStream<String, Error>,
                        accumulator: OpenAIStreamAccumulator)
    -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var acc = accumulator
            do {
                for try await line in lines {
                    if let text = acc.consume(line: line) { continuation.yield(.textDelta(text)) }
                }
                let calls = acc.finishToolCalls()
                if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                continuation.yield(.done)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

- [ ] **Step 3: Implement for Azure** (reuses OpenAI accumulator + driver)

In `AzureFoundryAgentProvider`:
```swift
func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                     options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
    let body: [String: Any] = [
        "messages": OpenAIAgentProvider.wireMessages(messages),
        "tools": tools.map(\.openAIFunctionSpec),
        "temperature": options.temperature,
        "max_tokens": options.maxTokens,
        "stream": true,
    ]
    let lines = AIStreamingHTTP.postLines(url: url, headers: ["api-key": config.apiKey], body: body)
    return OpenAIAgentProvider.eventStream(from: lines, accumulator: OpenAIStreamAccumulator())
}
```

- [ ] **Step 4: Implement for Anthropic**

In `AnthropicAgentProvider`. Anthropic needs its own driver because its accumulator type differs:
```swift
func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                     options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
    var body: [String: Any] = [
        "model": config.model,
        "max_tokens": options.maxTokens,
        "temperature": options.temperature,
        "messages": Self.wireMessages(messages),
        "tools": tools.map(\.anthropicToolSpec),
        "stream": true,
    ]
    if !system.isEmpty { body["system"] = system }
    let lines = AIStreamingHTTP.postLines(
        url: "\(config.baseURL)/v1/messages",
        headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
        body: body)
    return AsyncThrowingStream { continuation in
        let task = Task {
            var acc = AnthropicStreamAccumulator()
            do {
                for try await line in lines {
                    if let text = acc.consume(line: line) { continuation.yield(.textDelta(text)) }
                }
                let calls = acc.finishToolCalls()
                if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                continuation.yield(.done)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

- [ ] **Step 5: Implement for Ollama**

In `OllamaAgentProvider` (same driver shape with its accumulator):
```swift
func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                     options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let body: [String: Any] = [
        "model": config.model,
        "messages": Self.wireMessages(messages),
        "tools": tools.map(\.openAIFunctionSpec),
        "stream": true,
        "options": ["temperature": options.temperature],
    ]
    let lines = AIStreamingHTTP.postLines(url: "\(config.baseURL)/api/chat", headers: [:], body: body)
    return AsyncThrowingStream { continuation in
        let task = Task {
            var acc = OllamaStreamAccumulator()
            do {
                for try await line in lines {
                    if let text = acc.consume(line: line) { continuation.yield(.textDelta(text)) }
                }
                let calls = acc.finishToolCalls()
                if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                continuation.yield(.done)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!` The protocol now requires `streamWithTools` on all four providers - confirm all four implement it (compiler enforces). If any other type conforms to `AIAgentProvider`, it must implement it too.

- [ ] **Step 7: Commit**

```bash
git add Sources/Clippy/AI/AIAgent.swift
git commit -m "feat(ai): streamWithTools for OpenAI, Azure, Anthropic, Ollama"
```

## Task 5: Streaming agent loop

**Files:**
- Modify: `Sources/Clippy/AI/AIAgent.swift`

- [ ] **Step 1: Add `AIAgent.streamWithTools`**

Mirror `completeWithTools`'s control flow (max 8 rounds, sentinel tool results) but stream events:
```swift
static func streamWithTools(
    messages initialMessages: [AIMessage],
    provider: AIAgentProvider,
    tools: [AITool],
    options: AICompletionOptions = AICompletionOptions()
) -> AsyncThrowingStream<AIAgentEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var messages = initialMessages
            let maxRounds = 8
            var round = 0
            do {
                while round < maxRounds {
                    round += 1
                    var collectedCalls: [AIToolCall] = []
                    for try await event in provider.streamWithTools(messages, tools: tools, options: options) {
                        switch event {
                        case .textDelta(let t): continuation.yield(.textDelta(t))
                        case .toolCalls(let calls): collectedCalls = calls
                        case .done: break
                        }
                    }
                    if collectedCalls.isEmpty {
                        continuation.finish(); return
                    }
                    // Record the assistant tool-call turn, then run each tool.
                    messages.append(AIMessage(role: .assistant,
                                              content: encodeToolCallsForHistory(collectedCalls)))
                    for call in collectedCalls {
                        continuation.yield(.toolStarted(call.toolName))
                        let result: String
                        if let tool = tools.first(where: { $0.name == call.toolName }) {
                            do { result = try await tool.execute(args: call.arguments) }
                            catch { result = "Tool error: \(error.localizedDescription)" }
                        } else {
                            result = "Error: unknown tool \"\(call.toolName)\"."
                        }
                        messages.append(AIMessage(role: .user,
                            content: AIToolResultSentinel.encode(id: call.id, toolName: call.toolName, result: result)))
                        continuation.yield(.toolFinished(call.toolName))
                    }
                }
                // Round cap: one final non-streaming summary turn.
                messages.append(AIMessage(role: .user, content: "Summarise what you accomplished for the user."))
                let summary = try await provider.complete(messages, options: options)
                continuation.yield(.textDelta(summary))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

Confirm the real names of `encodeToolCallsForHistory` and `AIToolResultSentinel.encode` by reading `completeWithTools` (`:63-116`) and reuse them EXACTLY. If `encodeToolCallsForHistory` is `private`, either reuse it (same file, so accessible) or inline the same logic it uses.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Clippy/AI/AIAgent.swift
git commit -m "feat(ai): streaming agent loop with tool start/finish events"
```

## Task 6: MarkdownUI theme

**Files:**
- Create: `Sources/Clippy/AI/MarkdownTheme.swift`

- [ ] **Step 1: Create the theme**

```swift
import SwiftUI
import MarkdownUI

extension MarkdownUI.Theme {
    /// A Markdown theme mapped onto Clippy's token + typography system so
    /// assistant replies match the panel, with real fenced code blocks.
    static func clippy(tokens: ThemeTokens, settings: AppSettings) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(tokens.textPrimary)
                FontSize(settings.fontSizeBase)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(settings.fontSizeBase * 0.92)
                BackgroundColor(tokens.cardSurface)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(settings.fontSizeBase * 0.92)
                            ForegroundColor(tokens.textPrimary)
                        }
                }
                .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))
                .markdownMargin(top: 6, bottom: 6)
            }
            .link { ForegroundColor(tokens.accent) }
    }
}
```

Before building: the MarkdownUI theme DSL (`.text`, `.code`, `.codeBlock`, `.link`, `BackgroundColor`, `FontSize`, `FontFamilyVariant`, `ForegroundColor`, `markdownTextStyle`, `markdownMargin`) is version-specific. After adding the dependency in Task 1 you have the resolved version; if any modifier name differs in that version, adjust to the real API (the package's `Theme` and `TextStyle` types). If the DSL differs substantially, implement the closest equivalent that yields: themed body text, monospaced inline code with a subtle background, and fenced code blocks in a bordered monospace box. Confirm `settings.fontSizeBase` is the real property name (used by `PanelTypography`); if not, use the real base-size property.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Clippy/AI/MarkdownTheme.swift
git commit -m "feat(ai): Clippy-themed Markdown rendering theme"
```

## Task 7: Rewrite the view model (streaming + stop + safe confirmation)

**Files:**
- Modify: `Sources/Clippy/AI/AIAssistantPanelView.swift` (the `AIAssistantViewModel` class, `:28-153`)

- [ ] **Step 1: Replace the State enum and add task/stop**

Change `State` to:
```swift
enum State: Equatable { case ready, streaming, notConfigured(String) }
```
Add a stored property:
```swift
private var runningTask: Task<Void, Never>?
```
Add:
```swift
func stop() { runningTask?.cancel() }
```

- [ ] **Step 2: Rewrite `send()` to consume the streaming loop**

Keep the existing config/provider/registry construction (`:56-100`) verbatim. Replace the `state = .thinking` with `state = .streaming`, and replace the `Task { ... completeWithTools ... }` block (`:90-116`) with:
```swift
runningTask = Task { [weak self] in
    guard let self else { return }
    defer { self.state = .ready; self.runningTask = nil }   // ALWAYS resets state
    var buffer = ""
    var lastFlush = Date()
    func flush() { self.messages[assistantIndex].text += buffer; buffer = "" ; lastFlush = Date() }
    do {
        for try await event in AIAgent.streamWithTools(messages: history, provider: provider, tools: registry.all) {
            if Task.isCancelled { break }
            switch event {
            case .textDelta(let t):
                buffer += t
                if Date().timeIntervalSince(lastFlush) > 0.05 { flush() }   // ~20fps coalesce
            case .toolStarted(let name):
                flush()
                self.messages[assistantIndex].toolActivities.append(.running(name))
            case .toolFinished(let name):
                if let i = self.messages[assistantIndex].toolActivities.firstIndex(of: .running(name)) {
                    self.messages[assistantIndex].toolActivities[i] = .done(name)
                }
            }
        }
        flush()
    } catch is CancellationError {
        flush()   // keep partial text; not an error
    } catch {
        flush()
        ClippyLog.error("AI agent error: \(error)", category: ClippyLog.ai)
        if self.messages[assistantIndex].text.isEmpty {
            self.messages[assistantIndex].text = error.localizedDescription
            self.messages[assistantIndex].isError = true
        }
    }
}
```
`assistantIndex` and `history` are computed exactly as today (`:84-88`). Keep `ClippyLog.error(...)` matching the existing call (`:111`).

- [ ] **Step 3: Rewrite confirmation to be single-resume and dismiss-safe**

Keep `PendingConfirmation` but make `resolve` idempotent:
```swift
private func askConfirmation(_ prompt: String) async -> Bool {
    await withCheckedContinuation { cont in
        pendingConfirmation = PendingConfirmation(prompt: prompt, continuation: cont)
    }
}

func resolveConfirmation(_ allowed: Bool) {
    guard let confirmation = pendingConfirmation else { return }
    pendingConfirmation = nil                       // clear FIRST so any re-entry is a no-op
    confirmation.continuation?.resume(returning: allowed)
}
```
Add a safety net used by the inline card's dismiss path (Task 8) and by `stop()`:
```swift
func cancelPendingConfirmation() { resolveConfirmation(false) }
```
Also call `cancelPendingConfirmation()` inside `stop()` before/after cancelling the task, so cancelling mid-confirmation never orphans the continuation:
```swift
func stop() { cancelPendingConfirmation(); runningTask?.cancel() }
```

- [ ] **Step 4: Update `clearConversation`**

```swift
func clearConversation() {
    stop()
    messages = []
    state = .ready
    inputText = ""
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!` (the view still references `.thinking` in places - those are fixed in Task 8; if the build fails only on `.thinking`/`.sheet` references in the view, that's expected and resolved next. If you can, make Steps 1-5 and Task 8 in one build-clean commit set; otherwise temporarily keep the view compiling by mapping `.thinking` usages to `.streaming` now.)

To keep the build green at this commit, also do the trivial `.thinking` -> `.streaming` renames at the view's existing usage sites (`:310`, `:355-386` disabled checks) now; the full input-bar/Stop rewrite is Task 8.

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/AI/AIAssistantPanelView.swift
git commit -m "feat(ai): streaming view model with stop, timeouts-safe lifecycle, single-resume confirmation"
```

## Task 8: Rewrite the views (markdown bubble, Stop button, inline confirmation)

**Files:**
- Modify: `Sources/Clippy/AI/AIAssistantPanelView.swift` (the `body`, `inputBar`, `MessageBubble`, remove `.sheet`, remove/repurpose `ToolConfirmationSheet`)

- [ ] **Step 1: Render assistant markdown in `MessageBubble`**

Add `import MarkdownUI` at the top of the file. In `MessageBubble` (`:394-459`), replace the assistant-text `Text(message.text...)` branch (`:413`) with MarkdownUI while keeping user + error branches as-is:
```swift
} else if message.role == .assistant {
    Markdown(message.text.isEmpty ? " " : message.text)
        .markdownTheme(.clippy(tokens: tokens, settings: settings))
} else {
    Text(message.text.isEmpty ? " " : message.text)
        .font(PanelTypography.body(settings))
        .foregroundStyle(tokens.isDark ? Color.white : Color(nsColor: .labelColor).opacity(0.9))
}
```
Keep the `.textSelection(.enabled)`, padding, and bubble background exactly as they are.

- [ ] **Step 2: Replace the `.sheet` with an inline confirmation overlay**

Remove the `.sheet(item: $vm.pendingConfirmation) { ... }` modifier from `body` (`:177-183`). Wrap the body content in a `ZStack` (or add `.overlay`) so that when `vm.pendingConfirmation != nil`, an inline card is shown above the thread:
```swift
var body: some View {
    ZStack {
        VStack(spacing: 0) {
            header; Divider(); content; Divider(); inputBar
        }
        if let confirmation = vm.pendingConfirmation {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { vm.cancelPendingConfirmation() }
            InlineConfirmationCard(
                prompt: confirmation.prompt,
                tokens: tokens, settings: settings,
                onAllow: { vm.resolveConfirmation(true) },
                onDeny: { vm.resolveConfirmation(false) }
            )
            .padding(24)
        }
    }
}
```

- [ ] **Step 3: Add `InlineConfirmationCard`**

Repurpose `ToolConfirmationSheet`'s body into a card view (same content, no sheet semantics):
```swift
private struct InlineConfirmationCard: View {
    let prompt: String
    let tokens: ThemeTokens
    let settings: AppSettings
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Confirm action", systemImage: "exclamationmark.shield")
                .font(PanelTypography.body(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
            Text("The assistant wants to run this. Review before allowing.")
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
            ScrollView {
                Text(prompt)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))
            HStack {
                Button("Deny", role: .cancel, action: onDeny).keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Allow", action: onAllow).keyboardShortcut(.return, modifiers: []).buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(tokens.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tokens.cardBorder, lineWidth: 1))
        .shadow(radius: 20)
    }
}
```
Delete the now-unused `ToolConfirmationSheet` struct (or leave it if referenced elsewhere - grep `ToolConfirmationSheet`; it should only be in this file).

- [ ] **Step 4: Input bar - Stop while streaming**

In `inputBar` (`:351-391`), make the trailing button context-sensitive. When `vm.state == .streaming`, show a Stop button calling `vm.stop()`; otherwise the send arrow:
```swift
Button {
    if vm.state == .streaming { vm.stop() } else { vm.send() }
} label: {
    Image(systemName: vm.state == .streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
        .font(.system(size: 22))
        .foregroundStyle(
            vm.state == .streaming ? tokens.accent
            : (vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tokens.textSecondary : tokens.accent))
}
.buttonStyle(.plain)
.disabled(vm.state != .streaming && vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
```
Update `.onSubmit` so it only sends when `state == .ready`. Update the "Thinking..." indicator (`:310`) to show while `state == .streaming` and the live bubble is still empty (so it disappears as soon as the first delta lands).

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!` (no remaining `.thinking` references; no `.sheet`).

- [ ] **Step 6: Commit**

```bash
git add Sources/Clippy/AI/AIAssistantPanelView.swift
git commit -m "feat(ai): markdown bubbles, Stop button, inline confirmation card"
```

## Task 9: Final clean build + manual verification handoff

- [ ] **Step 1: Clean build**

Run: `rm -rf .build && swift build`
Expected: MarkdownUI resolves; `Build complete!` with no warnings introduced by this work.

- [ ] **Step 2: Manual verification (controller/user - needs GUI + a configured provider)**

Walk the spec's Verification list:
- First, second, and third messages each stream token-by-token and complete; no freeze on the second message.
- Assistant replies render markdown; fenced code blocks appear in a monospace bordered box.
- A tool-using turn shows "Running X..." then "Ran X"; the inline confirmation card appears; Allow, Deny, and click-away each resume cleanly and return state to ready.
- Stop cancels mid-stream; the chat returns to ready and accepts a new message.
- Forcing a provider error (bad key/URL) shows an error bubble and resets to ready - no lockup.

- [ ] **Step 3: Final commit only if fixes were needed; otherwise stop.**

---

## Self-review notes (author)

- **Spec coverage:** MarkdownUI dep -> Task 1; streaming transport -> Task 2; per-provider parsing -> Task 3; provider `streamWithTools` (all 4) -> Task 4; streaming agent loop -> Task 5; markdown theme -> Task 6; freeze-proof view model (defer reset, stop, single-resume confirmation, timeouts via Task 2) -> Task 7; markdown bubble + Stop + inline confirmation -> Task 8; clean build + manual gate -> Task 9. All design sections A-G covered.
- **Signature consistency:** `AIStreamEvent {textDelta,toolCalls,done}`, `AIAgentEvent {textDelta,toolStarted,toolFinished}`, `AIStreamingHTTP.postLines`, `provider.streamWithTools`, `AIAgent.streamWithTools`, `Theme.clippy(tokens:settings:)`, `resolveConfirmation`/`cancelPendingConfirmation`/`stop` used consistently across tasks.
- **Reused-unchanged contracts:** `wireMessages` (per provider), `openAIFunctionSpec`/`anthropicToolSpec`, `AIToolResultSentinel.encode`, `encodeToolCallsForHistory`, `AIToolCall`, `AIError.badURL/.http`, `AIToolRegistry.makeFiltered`, `confirmHook`. Each pinned to its source so the implementer matches real names.
- **Known API-shape unknowns flagged inline:** the MarkdownUI theme DSL (version-specific, confirm after Task 1), `settings.fontSizeBase` name, `encodeToolCallsForHistory` visibility, `AIError` case names. Each tied to a real call site to read.
- **Toolchain:** XCTest can't run; `swift build` + manual chat run are the gate, with DEFERRED TEST notes for the stream parsers.
- **Build-continuity caveat:** Task 7 touches the VM while the view still references old state; the plan renames `.thinking` usages in Task 7 Step 5 so each commit stays build-green, with the full view rewrite in Task 8.

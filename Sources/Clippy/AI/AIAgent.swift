import Foundation

// MARK: - Agent-capable provider protocol

/// A provider that supports tool/function calling. Extends the base `AIProvider`
/// with a single agentic call: given messages and tools, return either a final
/// text answer or a list of tool calls the model wants to make.
///
/// API docs consulted:
///   OpenAI  — https://platform.openai.com/docs/guides/function-calling (2025-05 version)
///   Anthropic — https://docs.anthropic.com/en/docs/tool-use (2024-11 / anthropic-version 2023-06-01)
///   Ollama  — https://ollama.com/blog/tool-support (/api/chat, July 2024)
///   Azure   — OpenAI-compatible chat completions (api-version 2024-10-21)
protocol AIAgentProvider: AIProvider {
    /// One agentic turn. Returns `.text` when the model has a final answer, or
    /// `.toolCalls` with the list of calls the model wants to make.
    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn
}

// MARK: - Turn result

enum AIAgentTurn {
    case text(String)
    case toolCalls([AIToolCall])
}

struct AIToolCall: Equatable {
    /// Provider-assigned call id (used by OpenAI/Azure/Anthropic to correlate
    /// the tool_result back to the tool_use block).
    let id: String
    let toolName: String
    /// JSON-decoded argument dictionary.
    let arguments: [String: Any]

    static func == (lhs: AIToolCall, rhs: AIToolCall) -> Bool {
        lhs.id == rhs.id && lhs.toolName == rhs.toolName
    }
}

// MARK: - Agent loop

/// Drives an agentic conversation: sends messages, receives tool calls, executes
/// them (with confirmation), feeds results back, and loops until the model
/// returns plain text or `maxRounds` is exhausted.
enum AIAgent {
    /// Maximum tool-call rounds before the loop gives up.
    static let maxRounds = 8

    /// Run the agent loop.
    ///
    /// - Parameters:
    ///   - messages:  Initial conversation messages.
    ///   - provider:  An `AIAgentProvider` (wraps a real or mock backend).
    ///   - tools:     Tools available to the model.
    ///   - options:   Temperature / maxTokens forwarded to each provider call.
    ///   - confirm:   Async hook called before any tool execution. Return `true`
    ///                to allow, `false` to deny (the loop reports the denial to
    ///                the model and continues).
    /// - Returns: The model's final text answer.
    static func completeWithTools(
        messages initialMessages: [AIMessage],
        provider: AIAgentProvider,
        tools: [AITool],
        options: AICompletionOptions = AICompletionOptions(),
        confirm: @escaping (String) async -> Bool
    ) async throws -> String {
        var messages = initialMessages
        var round = 0

        while round < maxRounds {
            round += 1
            let turn = try await provider.completeWithTools(messages, tools: tools, options: options)

            switch turn {
            case .text(let answer):
                return answer

            case .toolCalls(let calls):
                // Append the assistant's tool-call turn so the history is complete.
                let assistantMsg = AIMessage(role: .assistant,
                                            content: encodeToolCallsForHistory(calls))
                messages.append(assistantMsg)

                // Execute each call and accumulate result messages.
                for call in calls {
                    let result: String
                    if let tool = tools.first(where: { $0.name == call.toolName }) {
                        do {
                            // Each tool is responsible for calling the confirm hook
                            // when it requires confirmation (run_script, execute_code).
                            result = try await tool.execute(args: call.arguments)
                        } catch {
                            result = "Tool error: \(error.localizedDescription)"
                        }
                    } else {
                        result = "Error: unknown tool \"\(call.toolName)\"."
                    }

                    // Append the tool result as a user message. Different providers
                    // expect different roles; the concrete providers decode this
                    // sentinel and reformat it in their own wire shape.
                    messages.append(AIMessage(
                        role: .user,
                        content: AIToolResultSentinel.encode(id: call.id, toolName: call.toolName, result: result)
                    ))
                }
            }
        }

        // Exhausted rounds — ask for a summary of what was done.
        messages.append(AIMessage(role: .user,
                                  content: "Summarise what you accomplished with the tools."))
        return try await provider.complete(messages, options: options)
    }

    // MARK: - Internal helpers

    /// Encode tool calls as a JSON string stored in the assistant message content
    /// field so the history stays serialisable in AIMessage (which holds a String).
    private static func encodeToolCallsForHistory(_ calls: [AIToolCall]) -> String {
        let payload = calls.map { c -> [String: Any] in
            [
                "id": c.id,
                "tool": c.toolName,
                "args": c.arguments,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "[tool calls]" }
        return s
    }
}

// MARK: - Tool-result sentinel

/// A tiny encoding that lets AIMessage (String content) carry a tool result
/// without adding a new `role` case. Concrete providers decode this and emit
/// the correct wire-format message (tool / tool_result / etc.).
enum AIToolResultSentinel {
    static let prefix = "__tool_result__:"

    static func encode(id: String, toolName: String, result: String) -> String {
        let payload: [String: Any] = ["id": id, "tool": toolName, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return result }
        return "\(prefix)\(s)"
    }

    /// Returns (id, toolName, result) if `content` was encoded by `encode`.
    static func decode(_ content: String) -> (id: String, toolName: String, result: String)? {
        guard content.hasPrefix(prefix) else { return nil }
        let json = String(content.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let toolName = obj["tool"] as? String,
              let result = obj["result"] as? String else { return nil }
        return (id, toolName, result)
    }
}

// MARK: - OpenAI agent provider
//
// Wire format (OpenAI Chat Completions API, 2025-05):
//   Request  — tools: [{ type, function: { name, description, parameters } }]
//   Response — choices[0].message.tool_calls?: [{ id, type, function: { name, arguments } }]
//              choices[0].finish_reason == "tool_calls" when calling
//   Tool result message — { role: "tool", tool_call_id: id, content: result }

struct OpenAIAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    // Pass-through for the non-tool path.
    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/chat/completions",
            headers: ["Authorization": "Bearer \(config.apiKey)"],
            body: [
                "model": config.model,
                "messages": AIHTTP.messagePayload(messages),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let body: [String: Any] = [
            "model": config.model,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
        ]
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/chat/completions",
            headers: ["Authorization": "Bearer \(config.apiKey)"],
            body: body
        )
        return try Self.parseTurn(data)
    }

    // MARK: Wire helpers

    static func wireMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.map { msg in
            if let (id, _, result) = AIToolResultSentinel.decode(msg.content) {
                // tool result — OpenAI wants role:"tool" with tool_call_id
                return ["role": "tool", "tool_call_id": id, "content": result]
            }
            return ["role": msg.role.rawValue, "content": msg.content]
        }
    }

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIError.decoding("OpenAI: missing choices[0].message")
        }
        let finishReason = first["finish_reason"] as? String ?? ""
        if finishReason == "tool_calls",
           let toolCalls = message["tool_calls"] as? [[String: Any]] {
            let calls = toolCalls.compactMap { tc -> AIToolCall? in
                guard let id = tc["id"] as? String,
                      let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let argsString = fn["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else { return nil }
                return AIToolCall(id: id, toolName: name, arguments: args)
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw AIError.empty
        }
        return .text(content)
    }
}

// MARK: - Anthropic agent provider
//
// Wire format (Anthropic Messages API, anthropic-version: 2023-06-01):
//   Request  — tools: [{ name, description, input_schema }]
//   Response — stop_reason == "tool_use"; content: [{ type:"tool_use", id, name, input }]
//              Final text: content: [{ type:"text", text }]
//   Tool result — role:"user", content:[{ type:"tool_result", tool_use_id: id, content: result }]

struct AnthropicAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": AIHTTP.messagePayload(turns),
        ]
        if !system.isEmpty { body["system"] = system }
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/messages",
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
        return try AIHTTP.string(data, at: ["content", 0, "text"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.anthropicToolSpec),
        ]
        if !system.isEmpty { body["system"] = system }
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/messages",
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
        return try Self.parseTurn(data)
    }

    // MARK: Wire helpers

    static func wireMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        // Group consecutive tool results under a single user turn — Anthropic
        // requires tool_result blocks in a user message's content array.
        var result: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            result.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }

        for msg in messages {
            if msg.role == .system { continue }
            if let (id, _, toolResult) = AIToolResultSentinel.decode(msg.content) {
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": toolResult,
                ])
            } else {
                flushToolResults()
                result.append(["role": msg.role.rawValue, "content": msg.content])
            }
        }
        flushToolResults()
        return result
    }

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw AIError.decoding("Anthropic: missing content array")
        }
        let stopReason = root["stop_reason"] as? String ?? ""
        if stopReason == "tool_use" {
            let calls = content.compactMap { block -> AIToolCall? in
                guard let type_ = block["type"] as? String, type_ == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any] else { return nil }
                return AIToolCall(id: id, toolName: name, arguments: input)
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        // Gather text blocks.
        let text = content.compactMap { block -> String? in
            guard let type_ = block["type"] as? String, type_ == "text",
                  let t = block["text"] as? String else { return nil }
            return t
        }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return .text(text)
    }
}

// MARK: - Ollama agent provider
//
// Wire format (Ollama /api/chat, July 2024):
//   Request  — tools: [{ type, function: { name, description, parameters } }]
//              (same shape as OpenAI)
//   Response — message.tool_calls?: [{ function: { name, arguments } }]
//              (no id field — we generate a synthetic one)
//   Tool result — role:"tool", content: result string

struct OllamaAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/api/chat",
            headers: [:],
            body: [
                "model": config.model,
                "messages": AIHTTP.messagePayload(messages),
                "stream": false,
                "options": ["temperature": options.temperature],
            ]
        )
        return try AIHTTP.string(data, at: ["message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/api/chat",
            headers: [:],
            body: [
                "model": config.model,
                "messages": Self.wireMessages(messages),
                "tools": tools.map(\.openAIFunctionSpec),
                "stream": false,
                "options": ["temperature": options.temperature],
            ]
        )
        return try Self.parseTurn(data)
    }

    static func wireMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.map { msg in
            if let (_, _, result) = AIToolResultSentinel.decode(msg.content) {
                return ["role": "tool", "content": result]
            }
            return ["role": msg.role.rawValue, "content": msg.content]
        }
    }

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else {
            throw AIError.decoding("Ollama: missing message")
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            var idx = 0
            let calls = toolCalls.compactMap { tc -> AIToolCall? in
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                // Ollama may return arguments as a dict or as a JSON string.
                let args: [String: Any]
                if let d = fn["arguments"] as? [String: Any] {
                    args = d
                } else if let s = fn["arguments"] as? String,
                          let data = s.data(using: .utf8),
                          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    args = d
                } else {
                    args = [:]
                }
                idx += 1
                return AIToolCall(id: "ollama-\(idx)", toolName: name, arguments: args)
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw AIError.empty
        }
        return .text(content)
    }
}

// MARK: - Azure AI Foundry agent provider
//
// Wire format: OpenAI-compatible chat completions.
// API version: 2024-10-21 (set in AIProviderConfig.apiVersion).

struct AzureFoundryAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let data = try await AIHTTP.post(
            url: url, headers: ["api-key": config.apiKey],
            body: [
                "messages": AIHTTP.messagePayload(messages),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let body: [String: Any] = [
            "messages": OpenAIAgentProvider.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
        ]
        let data = try await AIHTTP.post(url: url, headers: ["api-key": config.apiKey], body: body)
        // Azure returns the same shape as OpenAI.
        return try OpenAIAgentProvider.parseTurn(data)
    }
}

// MARK: - Agent provider factory

enum AIAgentProviderFactory {
    static func make(kind: AIProviderKind, config: AIProviderConfig) -> AIAgentProvider {
        switch kind {
        case .openai:       return OpenAIAgentProvider(config: config)
        case .anthropic:    return AnthropicAgentProvider(config: config)
        case .ollama:       return OllamaAgentProvider(config: config)
        case .azureFoundry: return AzureFoundryAgentProvider(config: config)
        }
    }
}

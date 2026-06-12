import Foundation

// MARK: - Tool protocol

/// A tool the agent loop may call. The engine serializes `parameters` into the
/// provider's function-calling schema; `execute` runs on the app side and returns
/// a plain-text result (or an error description) for the model to read.
///
/// `execute` receives the raw JSON-decoded argument dictionary that the model
/// filled in. Return a string of at most `AIToolDefinition.maxResultBytes` bytes;
/// the engine truncates longer outputs before feeding them back.
protocol AITool {
    var name: String { get }
    var description: String { get }
    /// JSON Schema object describing the function's parameters.
    var parametersSchema: [String: Any] { get }
    func execute(args: [String: Any]) async throws -> String
}

extension AITool {
    /// Serialise this tool into the OpenAI / Ollama / Azure function-calling
    /// wire format: `{ type, function: { name, description, parameters } }`.
    var openAIFunctionSpec: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersSchema,
            ] as [String: Any],
        ]
    }

    /// Serialise into the Anthropic tools array format:
    /// `{ name, description, input_schema }`.
    var anthropicToolSpec: [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": parametersSchema,
        ]
    }
}

// MARK: - Registry

/// Central registry for tools available to the agent loop.
/// Register tools once at startup; the loop queries via name at runtime.
final class AIToolRegistry {
    private var tools: [String: AITool] = [:]

    func register(_ tool: AITool) {
        tools[tool.name] = tool
    }

    func tool(named name: String) -> AITool? {
        tools[name]
    }

    var all: [AITool] { Array(tools.values) }
}

// MARK: - Safety constants

extension AITool {
    /// Truncate tool results to this many bytes before feeding back to the model.
    static var maxResultBytes: Int { AIToolHelpers.maxResultBytes }
}

/// Free-function helpers for tool implementations. Using a free enum instead of
/// a protocol extension avoids the "static member cannot be used on protocol
/// metatype" limitation in Swift.
enum AIToolHelpers {
    static let maxResultBytes = 4096

    static func truncate(_ s: String) -> String {
        guard s.utf8.count > maxResultBytes else { return s }
        // Slice to maxResultBytes UTF-8 units. Using Data -> String avoids the
        // broken-trailing-byte problem: String(data:encoding:) returns nil when
        // the boundary falls inside a multi-byte sequence; drop 1 byte at a time
        // until it succeeds (at most 3 iterations for any valid UTF-8 codepoint).
        var count = maxResultBytes
        while count > 0 {
            let slice = Data(s.utf8.prefix(count))
            if let t = String(data: slice, encoding: .utf8) {
                return t + "\n[result truncated]"
            }
            count -= 1
        }
        return String(s.prefix(maxResultBytes)) + "\n[result truncated]"
    }
}

// MARK: - Built-in tools

// MARK: search_clips

/// Search the clip database by full-text query. Returns up to 10 matching clip
/// texts, separated by a numbered list.
struct SearchClipsTool: AITool {
    let name = "search_clips"
    let description = "Search the Clippy clipboard history by text. Returns up to 10 matching snippets."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Text to search for in the clipboard history.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["query"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: query parameter is required."
        }
        let clips = try ClipDatabase.shared.searchClips(matching: query, limit: 10)
        if clips.isEmpty { return "No clips found matching \"\(query)\"." }
        return clips.enumerated().map { (i, clip) in
            "\(i + 1). \(AIService.clamp(clip.contentText ?? "", 200))"
        }.joined(separator: "\n")
    }
}

// MARK: create_clip

/// Insert a new text clip into the database.
struct CreateClipTool: AITool {
    let name = "create_clip"
    let description = "Save a new text snippet to the Clippy clipboard history."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": [
                "type": "string",
                "description": "The text content of the new clip.",
            ] as [String: Any],
            "title": [
                "type": "string",
                "description": "Optional short title for the clip.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["text"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return "Error: text parameter is required."
        }
        let id = try ClipDatabase.shared.insertTextClip(text)
        return "Clip created with id \(id)."
    }
}

// MARK: list_scripts

/// List the names of all stored scripts.
struct ListScriptsTool: AITool {
    let name = "list_scripts"
    let description = "List all scripts saved in Clippy's script library by name."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String],
    ]

    let scriptStore: ScriptStore

    func execute(args: [String: Any]) async throws -> String {
        let names = scriptStore.scripts.map(\.name)
        if names.isEmpty { return "No scripts are saved." }
        return names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

// MARK: run_script

/// Run a stored script by name. Always gated by the caller-supplied confirmation
/// hook; the tool returns a denial message if the hook returns false.
struct RunScriptTool: AITool {
    let name = "run_script"
    let description = "Run one of the user's saved Clippy scripts. The user must confirm before execution."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script_name": [
                "type": "string",
                "description": "The exact name of the script to run.",
            ] as [String: Any],
            "input": [
                "type": "string",
                "description": "Optional text to pass to the script on stdin.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["script_name"],
    ]

    let scriptStore: ScriptStore
    /// Async confirmation hook — UI layer sets this to show an alert.
    let confirmHook: (String) async -> Bool

    func execute(args: [String: Any]) async throws -> String {
        guard let scriptName = args["script_name"] as? String else {
            return "Error: script_name parameter is required."
        }
        guard let script = scriptStore.scripts.first(where: { $0.name == scriptName }) else {
            return "Error: no script named \"\(scriptName)\"."
        }
        let input = args["input"] as? String
        let allowed = await confirmHook("Run script \"\(script.name)\"?")
        guard allowed else {
            return "User declined to run script \"\(script.name)\"."
        }
        let result = await ScriptRunner.run(script, input: input, timeout: 30)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return AIToolHelpers.truncate(result.succeeded
            ? output
            : "Script failed (exit \(result.exitCode)): \(output)")
    }
}

// MARK: execute_code

/// Materialize a transient script from the model-generated code and run it via
/// ScriptRunner. ALWAYS gated by the confirmation hook.
struct ExecuteCodeTool: AITool {
    let name = "execute_code"
    let description = "Execute code generated by the AI. The user must confirm before execution. The code runs in a sandboxed subprocess with a 30-second timeout."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "language": [
                "type": "string",
                "enum": ["zsh", "bash", "python3", "node", "ruby", "swift"],
                "description": "The interpreter to use.",
            ] as [String: Any],
            "code": [
                "type": "string",
                "description": "The code to execute.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["language", "code"],
    ]

    /// Async confirmation hook supplied by the UI layer.
    let confirmHook: (String) async -> Bool

    func execute(args: [String: Any]) async throws -> String {
        guard let languageRaw = args["language"] as? String,
              let interpreter = ScriptInterpreter(rawValue: languageRaw),
              let code = args["code"] as? String, !code.isEmpty else {
            return "Error: language and code parameters are required."
        }

        // Safety: always gate behind confirmation.
        let preview = String(code.prefix(200))
        let allowed = await confirmHook("Execute \(languageRaw) code?\n\n\(preview)\(code.count > 200 ? "..." : "")")
        guard allowed else {
            return "User declined to execute the generated code."
        }

        let transient = Script(
            name: "AI-generated (\(languageRaw))",
            interpreter: interpreter,
            body: code,
            feedsClipboard: false,
            outputToClipboard: false
        )
        let result = await ScriptRunner.run(transient, input: nil, timeout: 30)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return AIToolHelpers.truncate(result.succeeded
            ? output
            : "Execution failed (exit \(result.exitCode)): \(output)")
    }
}

// MARK: - Default registry factory

extension AIToolRegistry {
    /// Build a registry with all built-in tools wired to the shared stores and
    /// the supplied confirmation hook. The UI layer passes a hook that shows an
    /// alert; tests pass a closure that returns a fixed bool.
    static func makeDefault(confirmHook: @escaping (String) async -> Bool) -> AIToolRegistry {
        let registry = AIToolRegistry()
        registry.register(SearchClipsTool())
        registry.register(CreateClipTool())
        registry.register(ListScriptsTool(scriptStore: .shared))
        registry.register(RunScriptTool(scriptStore: .shared, confirmHook: confirmHook))
        registry.register(ExecuteCodeTool(confirmHook: confirmHook))
        return registry
    }
}

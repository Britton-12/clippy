import Foundation

/// A proposed change produced by an AI action. The UI shows `original` vs
/// `proposed` and only writes after the user confirms (preview + confirm).
struct AIProposal: Equatable {
    enum Kind: Equatable {
        case title
        case rewrite
        case category
        case summary
        case newClip
        /// Result should be written to NSPasteboard; source clip is not modified.
        case copyToClipboard
    }
    let kind: Kind
    let label: String
    let original: String?
    let proposed: String
}

/// High-level AI actions over clips. Depends only on `AIProvider`, so the prompt
/// construction and response handling are unit-testable with a mock. All writes
/// happen in the UI layer after the user approves the returned proposal.
final class AIService {
    private let provider: AIProvider

    init(provider: AIProvider) {
        self.provider = provider
    }

    // MARK: - Construction from settings

    /// Build a service from the current settings + keychain, or explain why not.
    static func fromSettings(_ settings: AppSettings = .shared,
                             keychain: KeychainStore = .shared) -> Result<AIService, AIError> {
        guard settings.aiEnabled else {
            return .failure(.notConfigured("AI features are turned off in Settings."))
        }
        let kind = settings.aiProvider
        let base = settings.aiBaseURL.isEmpty ? kind.defaultBaseURL : settings.aiBaseURL
        let model = settings.aiModel.isEmpty ? kind.defaultModel : settings.aiModel
        if let why = kind.endpointConfigError(base) {
            return .failure(.notConfigured(why))
        }
        var key = ""
        if kind.needsAPIKey {
            key = keychain.read(account: kind.keychainAccount) ?? ""
            if key.isEmpty {
                return .failure(.notConfigured("\(kind.displayName) needs an API key (set it in Settings)."))
            }
        }
        let config = AIProviderConfig(baseURL: base, apiKey: key, model: model,
                                      apiVersion: settings.aiAzureAPIVersion)
        return .success(AIService(provider: AIProviderFactory.make(kind: kind, config: config)))
    }

    // MARK: - Actions

    func suggestTitle(forText text: String) async throws -> AIProposal {
        let out = try await provider.complete([
            AIMessage(role: .system, content: Prompts.title),
            AIMessage(role: .user, content: Self.clamp(text, 4000)),
        ], options: AICompletionOptions(temperature: 0.2, maxTokens: 32))
        return AIProposal(kind: .title, label: "Suggested title",
                          original: nil, proposed: Self.sanitizeTitle(out))
    }

    func rewrite(_ text: String, instruction: String) async throws -> AIProposal {
        let out = try await provider.complete([
            AIMessage(role: .system, content: Prompts.rewrite),
            AIMessage(role: .user, content: "Instruction: \(instruction)\n\nText:\n\(Self.clamp(text, 6000))"),
        ], options: AICompletionOptions(temperature: 0.4, maxTokens: 2048))
        return AIProposal(kind: .rewrite, label: "Rewrite (\(instruction))",
                          original: text, proposed: Self.trim(out))
    }

    func summarize(_ text: String) async throws -> AIProposal {
        let out = try await provider.complete([
            AIMessage(role: .system, content: Prompts.summary),
            AIMessage(role: .user, content: Self.clamp(text, 6000)),
        ], options: AICompletionOptions(temperature: 0.3, maxTokens: 256))
        return AIProposal(kind: .summary, label: "Summary", original: text, proposed: Self.trim(out))
    }

    /// Pick one of the existing categories, or nil when none fit (so the caller
    /// can offer to create one rather than forcing a bad match).
    func suggestCategory(forText text: String, categories: [String]) async throws -> AIProposal? {
        guard !categories.isEmpty else { return nil }
        let list = categories.map { "- \($0)" }.joined(separator: "\n")
        let out = try await provider.complete([
            AIMessage(role: .system, content: Prompts.category),
            AIMessage(role: .user, content: "Categories:\n\(list)\n\nItem:\n\(Self.clamp(text, 3000))"),
        ], options: AICompletionOptions(temperature: 0.0, maxTokens: 24))
        guard let match = Self.matchCategory(out, to: categories) else { return nil }
        return AIProposal(kind: .category, label: "Suggested category", original: nil, proposed: match)
    }

    /// Generate a brand-new clip based on the user's request and recent context
    /// (what they have been copying / their categories).
    func generateClip(request: String, context: String) async throws -> AIProposal {
        let out = try await provider.complete([
            AIMessage(role: .system, content: Prompts.generate),
            AIMessage(role: .user, content: "Context:\n\(Self.clamp(context, 3000))\n\nRequest: \(request)"),
        ], options: AICompletionOptions(temperature: 0.6, maxTokens: 1024))
        return AIProposal(kind: .newClip, label: "New clip", original: nil, proposed: Self.trim(out))
    }

    // MARK: - Custom action runner

    /// Execute a user-defined `AIAction` against the given clip text.
    /// The action's `promptTemplate` is rendered with `{clip}` and `{instruction}`
    /// before being sent as the user message. Returns an `AIProposal` shaped by
    /// the action's `outputDisposition`.
    func run(action: AIAction, on clipText: String, instruction: String = "") async throws -> AIProposal {
        let userPrompt = action.buildPrompt(clip: Self.clamp(clipText, 6000), instruction: instruction)
        let out = try await provider.complete([
            AIMessage(role: .user, content: userPrompt),
        ], options: AICompletionOptions(temperature: action.temperature, maxTokens: action.maxTokens))
        let trimmed = Self.trim(out)
        let kind: AIProposal.Kind
        switch action.outputDisposition {
        case .newClip:          kind = .newClip
        case .copyToClipboard:  kind = .copyToClipboard
        case .proposeEdit:      kind = .rewrite
        }
        return AIProposal(kind: kind, label: action.name, original: clipText, proposed: trimmed)
    }

    // MARK: - Response shaping (pure, tested)

    static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Titles must be one short line with no wrapping quotes or trailing period.
    /// Punctuation can sit either inside or outside the quotes (`"Title".`), so
    /// trailing punctuation is trimmed before and after unquoting.
    static func sanitizeTitle(_ raw: String) -> String {
        func stripTrailingPunctuation(_ x: String) -> String {
            var s = x
            while let last = s.last, last == "." || last == "," { s = String(s.dropLast()) }
            return trim(s)
        }
        var s = trim(raw).replacingOccurrences(of: "\n", with: " ")
        s = stripTrailingPunctuation(s)
        if s.count >= 2, let first = s.first, let last = s.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            s = trim(String(s.dropFirst().dropLast()))
        }
        s = stripTrailingPunctuation(s)
        return String(s.prefix(80))
    }

    /// Map a model's reply to one of the offered categories (exact, then
    /// case-insensitive, then containment), or nil for "NONE"/no match.
    static func matchCategory(_ raw: String, to categories: [String]) -> String? {
        let answer = trim(raw)
        if answer.isEmpty || answer.uppercased() == "NONE" { return nil }
        if let exact = categories.first(where: { $0 == answer }) { return exact }
        if let ci = categories.first(where: { $0.caseInsensitiveCompare(answer) == .orderedSame }) { return ci }
        return categories.first { answer.localizedCaseInsensitiveContains($0) }
    }

    static func clamp(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max))
    }

    private enum Prompts {
        static let title = "You write very short, descriptive titles (3 to 6 words) for clipboard snippets. Reply with only the title: no quotes, no surrounding text, no trailing punctuation."
        static let rewrite = "You rewrite text exactly as the user instructs. Reply with only the rewritten text and nothing else."
        static let summary = "Summarize the text in one or two plain sentences. Reply with only the summary."
        static let category = "Assign the item to exactly one category from the provided list. Reply with only the category name copied exactly as written. If none fit, reply with the single word NONE."
        static let generate = "You generate a single useful clipboard snippet based on the user's request and the provided context. Reply with only the snippet text, ready to paste."
    }
}

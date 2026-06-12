import Foundation
import Combine

// MARK: - Model

/// What the engine does with the text the model produces.
enum AIActionOutputDisposition: String, Codable, CaseIterable, Identifiable {
    /// Offer the result as an edit to the source clip (shows before/after diff).
    case proposeEdit
    /// Save the result as a brand-new clip.
    case newClip
    /// Copy the result to the system clipboard silently.
    case copyToClipboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proposeEdit:      return "Propose Edit"
        case .newClip:          return "New Clip"
        case .copyToClipboard:  return "Copy to Clipboard"
        }
    }
}

/// A user-definable AI action. Prompt templates may contain:
///   {clip}        — the full text of the source clip
///   {instruction} — an extra instruction the UI can supply at run time
///
/// Built-in defaults are shipped via `AIActionStore.seedDefaults()`.
struct AIAction: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// SF Symbol name shown in the UI.
    var symbolName: String
    /// System-prompt template. Use `{clip}` and `{instruction}` as placeholders.
    var promptTemplate: String
    var temperature: Double
    var maxTokens: Int
    var outputDisposition: AIActionOutputDisposition
    /// Built-in actions may not be deleted, only edited.
    var isBuiltIn: Bool

    // MARK: - Template rendering

    /// Substitute `{clip}` and `{instruction}`, then trim whitespace.
    func buildPrompt(clip: String, instruction: String = "") -> String {
        promptTemplate
            .replacingOccurrences(of: "{clip}", with: clip)
            .replacingOccurrences(of: "{instruction}", with: instruction)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Built-in defaults

extension AIAction {
    /// The seed set shipped with Clippy. Stored under stable UUIDs so they
    /// survive re-seeding without creating duplicates.
    static let builtIns: [AIAction] = [
        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
                 name: "Suggest Title",
                 symbolName: "textformat.size",
                 promptTemplate: "Write a short, descriptive title (3 to 6 words) for this clipboard snippet. Reply with only the title.\n\n{clip}",
                 temperature: 0.2, maxTokens: 32,
                 outputDisposition: .proposeEdit, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
                 name: "Rewrite",
                 symbolName: "pencil",
                 promptTemplate: "Rewrite the following text exactly as instructed. Reply with only the rewritten text.\n\nInstruction: {instruction}\n\nText:\n{clip}",
                 temperature: 0.4, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
                 name: "Summarize",
                 symbolName: "text.alignleft",
                 promptTemplate: "Summarize the following text in one or two plain sentences. Reply with only the summary.\n\n{clip}",
                 temperature: 0.3, maxTokens: 256,
                 outputDisposition: .proposeEdit, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!,
                 name: "Translate",
                 symbolName: "globe",
                 promptTemplate: "Translate the following text to {instruction}. Reply with only the translated text.\n\n{clip}",
                 temperature: 0.3, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!,
                 name: "Extract Key Points",
                 symbolName: "list.bullet",
                 promptTemplate: "Extract the key points from the following text as a short bulleted list. Reply with only the bullet points.\n\n{clip}",
                 temperature: 0.3, maxTokens: 512,
                 outputDisposition: .newClip, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!,
                 name: "Change Tone",
                 symbolName: "waveform",
                 promptTemplate: "Rewrite the following text in a {instruction} tone. Reply with only the rewritten text.\n\n{clip}",
                 temperature: 0.5, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000007")!,
                 name: "Generate Clip",
                 symbolName: "sparkles",
                 promptTemplate: "Generate a single useful clipboard snippet based on this request. Reply with only the snippet text.\n\nRequest: {instruction}\n\nContext:\n{clip}",
                 temperature: 0.6, maxTokens: 1024,
                 outputDisposition: .newClip, isBuiltIn: true),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000008")!,
                 name: "Suggest Category",
                 symbolName: "folder",
                 promptTemplate: "Assign this item to exactly one category from the provided list. Reply with only the category name. If none fit, reply NONE.\n\nCategories:\n{instruction}\n\nItem:\n{clip}",
                 temperature: 0.0, maxTokens: 24,
                 outputDisposition: .proposeEdit, isBuiltIn: true),
    ]
}

// MARK: - Store

/// Persists user-defined and built-in AI actions as a JSON file, following the
/// same pattern as ScriptStore. Injectable `fileURL` for tests.
final class AIActionStore: ObservableObject {
    static let shared = AIActionStore()

    @Published private(set) var actions: [AIAction] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
        seedDefaults()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-actions.json")
    }

    // MARK: - Seeding

    /// Insert built-ins that are not yet present. Safe to call on every launch
    /// because it checks by stable id, not by index.
    func seedDefaults() {
        var changed = false
        for builtIn in AIAction.builtIns {
            if !actions.contains(where: { $0.id == builtIn.id }) {
                actions.append(builtIn)
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - CRUD

    func add(_ action: AIAction) {
        actions.append(action)
        save()
    }

    func update(_ action: AIAction) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[index] = action
        save()
    }

    func delete(id: UUID) {
        // Built-ins may not be deleted.
        guard let target = actions.first(where: { $0.id == id }), !target.isBuiltIn else { return }
        actions.removeAll { $0.id == id }
        save()
    }

    func action(id: UUID) -> AIAction? {
        actions.first { $0.id == id }
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([AIAction].self, from: data) else { return }
        actions = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(actions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

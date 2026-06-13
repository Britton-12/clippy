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
struct AIAction: Identifiable, Equatable {
    var id: UUID
    var name: String
    /// How the icon is represented: SF Symbol, emoji, or app bundle ID.
    /// Defaults to `.symbol` so the synthesized memberwise init stays
    /// source-compatible with existing call sites that predate the icon-kind field.
    var iconKind: CategoryIconKind = .symbol
    /// The icon value: SF Symbol name, emoji character, or app bundle ID.
    /// Named `symbolName` for JSON compatibility with older saved actions.
    var symbolName: String
    /// System-prompt template. Use `{clip}` and `{instruction}` as placeholders.
    var promptTemplate: String
    var temperature: Double
    var maxTokens: Int
    var outputDisposition: AIActionOutputDisposition
    /// Built-in actions may not be deleted, only edited.
    var isBuiltIn: Bool
    /// User-defined display order. Lower values appear first. Defaults to 0 so
    /// JSON saved by older builds (which have no sortOrder key) migrates cleanly
    /// via `decodeIfPresent ?? 0`. Test call sites that omit sortOrder continue
    /// to compile because of this default.
    var sortOrder: Int = 0
}

// MARK: - Codable with migration

extension AIAction: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, iconKind, symbolName, promptTemplate
        case temperature, maxTokens, outputDisposition, isBuiltIn, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decode(String.self, forKey: .symbolName)
        // Old JSON has no `iconKind`; default to .symbol so existing actions
        // that stored an SF Symbol name in `symbolName` continue to render correctly.
        iconKind = try c.decodeIfPresent(CategoryIconKind.self, forKey: .iconKind) ?? .symbol
        promptTemplate = try c.decode(String.self, forKey: .promptTemplate)
        temperature = try c.decode(Double.self, forKey: .temperature)
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        outputDisposition = try c.decode(AIActionOutputDisposition.self, forKey: .outputDisposition)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        // Old JSON has no sortOrder; default to 0 so migration backfill runs in load().
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(iconKind, forKey: .iconKind)
        try c.encode(symbolName, forKey: .symbolName)
        try c.encode(promptTemplate, forKey: .promptTemplate)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(outputDisposition, forKey: .outputDisposition)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(sortOrder, forKey: .sortOrder)
    }
}

// MARK: - Template rendering

extension AIAction {
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
                 iconKind: .symbol, symbolName: "textformat.size",
                 promptTemplate: "Write a short, descriptive title (3 to 6 words) for this clipboard snippet. Reply with only the title.\n\n{clip}",
                 temperature: 0.2, maxTokens: 32,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 0),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
                 name: "Rewrite",
                 iconKind: .symbol, symbolName: "pencil",
                 promptTemplate: "Rewrite the following text exactly as instructed. Reply with only the rewritten text.\n\nInstruction: {instruction}\n\nText:\n{clip}",
                 temperature: 0.4, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 1),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
                 name: "Summarize",
                 iconKind: .symbol, symbolName: "text.alignleft",
                 promptTemplate: "Summarize the following text in one or two plain sentences. Reply with only the summary.\n\n{clip}",
                 temperature: 0.3, maxTokens: 256,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 2),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!,
                 name: "Translate",
                 iconKind: .symbol, symbolName: "globe",
                 promptTemplate: "Translate the following text to {instruction}. Reply with only the translated text.\n\n{clip}",
                 temperature: 0.3, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 3),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!,
                 name: "Extract Key Points",
                 iconKind: .symbol, symbolName: "list.bullet",
                 promptTemplate: "Extract the key points from the following text as a short bulleted list. Reply with only the bullet points.\n\n{clip}",
                 temperature: 0.3, maxTokens: 512,
                 outputDisposition: .newClip, isBuiltIn: true, sortOrder: 4),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!,
                 name: "Change Tone",
                 iconKind: .symbol, symbolName: "waveform",
                 promptTemplate: "Rewrite the following text in a {instruction} tone. Reply with only the rewritten text.\n\n{clip}",
                 temperature: 0.5, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 5),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000007")!,
                 name: "Generate Clip",
                 iconKind: .symbol, symbolName: "sparkles",
                 promptTemplate: "Generate a single useful clipboard snippet based on this request. Reply with only the snippet text.\n\nRequest: {instruction}\n\nContext:\n{clip}",
                 temperature: 0.6, maxTokens: 1024,
                 outputDisposition: .newClip, isBuiltIn: true, sortOrder: 6),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000008")!,
                 name: "Suggest Category",
                 iconKind: .symbol, symbolName: "folder",
                 promptTemplate: "Assign this item to exactly one category from the provided list. Reply with only the category name. If none fit, reply NONE.\n\nCategories:\n{instruction}\n\nItem:\n{clip}",
                 temperature: 0.0, maxTokens: 24,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 7),
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
                // Append after the current last entry to preserve user order.
                var seeded = builtIn
                seeded.sortOrder = (actions.map(\.sortOrder).max() ?? -1) + 1
                actions.append(seeded)
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - CRUD

    func add(_ action: AIAction) {
        var a = action
        a.sortOrder = (actions.map(\.sortOrder).max() ?? -1) + 1
        actions.append(a)
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

    /// Reorder: move the action identified by `draggedID` to just before the
    /// action identified by `targetID`. Built-ins are reorderable (only deletion
    /// is restricted). Resequences all sortOrder values gap-free and persists.
    func moveAction(draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let fromIndex = actions.firstIndex(where: { $0.id == draggedID }),
              actions.contains(where: { $0.id == targetID }) else { return }
        var reordered = actions
        let item = reordered.remove(at: fromIndex)
        let insertAt = reordered.firstIndex(where: { $0.id == targetID }) ?? reordered.endIndex
        reordered.insert(item, at: insertAt)
        // Resequence gap-free so sortOrder always reflects array position.
        for i in reordered.indices { reordered[i].sortOrder = i }
        actions = reordered
        save()
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([AIAction].self, from: data) else { return }
        // Sort by user-assigned order on every load.
        actions = decoded.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(actions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

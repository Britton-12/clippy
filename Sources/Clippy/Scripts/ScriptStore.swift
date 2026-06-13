import Foundation
import Combine

/// Persists the user's scripts as a JSON file. Decoupled from the clip database
/// since scripts are a small, separate concern. Injectable file URL for tests.
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()

    @Published private(set) var scripts: [Script] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scripts.json")
    }

    // MARK: - CRUD

    func add(_ script: Script) {
        var s = script
        s.sortOrder = (scripts.map(\.sortOrder).max() ?? -1) + 1
        scripts.append(s)
        save()
    }

    func update(_ script: Script) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        var updated = script
        updated.updatedAt = Date()
        scripts[index] = updated
        save()
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        save()
    }

    func script(id: UUID) -> Script? {
        scripts.first { $0.id == id }
    }

    /// Reorder: move the script identified by `draggedID` to just before the
    /// script identified by `targetID`. Resequences all sortOrder values
    /// gap-free and persists.
    func moveScript(draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let fromIndex = scripts.firstIndex(where: { $0.id == draggedID }),
              scripts.contains(where: { $0.id == targetID }) else { return }
        var reordered = scripts
        let item = reordered.remove(at: fromIndex)
        let insertAt = reordered.firstIndex(where: { $0.id == targetID }) ?? reordered.endIndex
        reordered.insert(item, at: insertAt)
        // Resequence gap-free so sortOrder always reflects array position.
        for i in reordered.indices { reordered[i].sortOrder = i }
        scripts = reordered
        save()
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Script].self, from: data) else { return }

        // Migration: if all sortOrder values are 0 (first load after upgrade from a
        // build without sortOrder), backfill sequential values from the current
        // alphabetical order so the visible list does not jump.
        let allZero = decoded.allSatisfy { $0.sortOrder == 0 }
        if allZero && decoded.count > 1 {
            let alphabetical = decoded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            scripts = alphabetical.enumerated().map { idx, s in
                var s = s; s.sortOrder = idx; return s
            }
            save()
        } else {
            scripts = decoded.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

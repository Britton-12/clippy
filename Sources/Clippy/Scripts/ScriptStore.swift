import Foundation
import Combine

/// Persists the user's scripts as a JSON file. Decoupled from the clip database
/// since scripts are a small, separate concern. Injectable file URL for tests.
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()

    @Published private(set) var scripts: [Script] = []

    private let store: JSONFileStore<Script>

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        store = JSONFileStore<Script>(
            fileURL: url,
            configureEncoder: { $0.dateEncodingStrategy = .iso8601 },
            configureDecoder: { $0.dateDecodingStrategy = .iso8601 }
        )
        // Migration: if all sortOrder values are 0 (first load after upgrade from a
        // build without sortOrder), backfill sequential values from the current
        // alphabetical order so the visible list does not jump.
        let loaded = store.items
        let allZero = loaded.allSatisfy { $0.sortOrder == 0 }
        if allZero && loaded.count > 1 {
            let alphabetical = loaded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let backfilled = alphabetical.enumerated().map { idx, s in
                var s = s; s.sortOrder = idx; return s
            }
            // Update through the store so it persists.
            for s in backfilled { store.update(s) }
            scripts = store.items.sorted { $0.sortOrder < $1.sortOrder }
        } else {
            scripts = loaded.sorted { $0.sortOrder < $1.sortOrder }
        }
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
        store.add(s)
        scripts = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func update(_ script: Script) {
        guard scripts.contains(where: { $0.id == script.id }) else { return }
        var updated = script
        updated.updatedAt = Date()
        store.update(updated)
        scripts = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func delete(id: UUID) {
        store.delete(id: id)
        scripts = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func script(id: UUID) -> Script? {
        scripts.first { $0.id == id }
    }

    /// Reorder: move the script identified by `draggedID` to just before the
    /// script identified by `targetID`. Resequences all sortOrder values
    /// gap-free and persists.
    func moveScript(draggedID: UUID, before targetID: UUID) {
        store.move(draggedID: draggedID, before: targetID)
        // Resequence gap-free so sortOrder always reflects array position.
        // The generic store only reorders the array; sortOrder renumbering is
        // Script-specific and stays here.
        var reordered = store.items
        for i in reordered.indices { reordered[i].sortOrder = i }
        for s in reordered { store.update(s) }
        scripts = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }
}

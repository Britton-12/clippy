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
        scripts.append(script)
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

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Script].self, from: data) else { return }
        scripts = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

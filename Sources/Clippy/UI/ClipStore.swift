import Foundation
import Combine
import GRDB

/// View model for the panel list: live database observation for recents,
/// FTS5 search when a query is typed.
final class ClipStore: ObservableObject {
    @Published var query: String = "" {
        didSet { refilter() }
    }
    @Published private(set) var clips: [Clip] = []

    private var recents: [Clip] = [] {
        didSet { refilter() }
    }
    private var observationCancellable: AnyDatabaseCancellable?
    private let database: ClipDatabase
    private let displayLimit = 300

    init(database: ClipDatabase) {
        self.database = database
        let limit = displayLimit
        let observation = ValueObservation.tracking { db in
            try Clip
                .order(Column("isPinned").desc, Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        observationCancellable = observation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("Clippy: clip observation failed: \(error)")
            },
            onChange: { [weak self] clips in
                self?.recents = clips
            }
        )
    }

    func togglePin(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? database.togglePin(id: id)
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? database.deleteClip(id: id)
    }

    func updateText(of clip: Clip, to newText: String) {
        guard let id = clip.id else { return }
        try? database.updateClipText(id: id, newText: newText)
    }

    private func refilter() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clips = recents
        } else {
            clips = (try? database.searchClips(matching: trimmed, limit: displayLimit)) ?? []
        }
    }
}

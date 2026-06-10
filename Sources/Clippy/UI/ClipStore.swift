import Foundation
import Combine
import GRDB

/// View model for the panel: live observation of clips, categories, and
/// membership; FTS5 search when a query is typed. "Pinned" is derived:
/// a clip is pinned when it belongs to at least one category.
final class ClipStore: ObservableObject {
    @Published var query: String = "" {
        didSet { refilter() }
    }
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var membership: [Int64: Set<Int64>] = [:]

    private var recents: [Clip] = [] {
        didSet { refilter() }
    }
    private var clipsCancellable: AnyDatabaseCancellable?
    private var categoriesCancellable: AnyDatabaseCancellable?
    private let database: ClipDatabase
    private let displayLimit = 300

    init(database: ClipDatabase) {
        self.database = database
        let limit = displayLimit
        // Two observations on purpose: clips churn on every copy, while categories
        // and membership change rarely; separating them avoids refetching the clip
        // window for every category edit.
        // Recents window plus every categorized clip: categorized clips must
        // stay visible in their panes even when older than the window.
        let clipObservation = ValueObservation.tracking { db in
            try Clip.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE id IN (SELECT clipID FROM clip_category)
                    OR id IN (SELECT id FROM clips ORDER BY createdAt DESC, id DESC LIMIT ?)
                    ORDER BY createdAt DESC, id DESC
                    """,
                arguments: [limit]
            )
        }
        clipsCancellable = clipObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("Clippy: clip observation failed: \(error)")
            },
            onChange: { [weak self] clips in
                self?.recents = clips
            }
        )

        let categoryObservation = ValueObservation.tracking { db -> ([Category], [Int64: Set<Int64>]) in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
            var map: [Int64: Set<Int64>] = [:]
            for row in rows {
                map[row["clipID"], default: []].insert(row["categoryID"])
            }
            return (categories, map)
        }
        categoriesCancellable = categoryObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("Clippy: category observation failed: \(error)")
            },
            onChange: { [weak self] categories, map in
                self?.categories = categories
                self?.membership = map
            }
        )
    }

    // MARK: - Derived data

    /// Distinct source apps seen in history, for category icon pickers.
    var knownBundleIDs: [String] {
        var seen = Set<String>()
        return clips.compactMap(\.sourceAppBundleID).filter { seen.insert($0).inserted }
    }

    // MARK: - Membership queries

    func isPinned(_ clip: Clip) -> Bool {
        guard let id = clip.id else { return false }
        return !(membership[id] ?? []).isEmpty
    }

    func categoryIDs(for clip: Clip) -> Set<Int64> {
        guard let id = clip.id else { return [] }
        return membership[id] ?? []
    }

    func clipCount(inCategory categoryID: Int64) -> Int {
        membership.values.reduce(0) { $0 + ($1.contains(categoryID) ? 1 : 0) }
    }

    // MARK: - Actions

    /// Toggles membership in the starter category (the Cmd+P fast path).
    func togglePin(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? database.toggleStarterMembership(clipID: id)
    }

    func setClip(_ clip: Clip, inCategory categoryID: Int64, _ isMember: Bool) {
        guard let id = clip.id else { return }
        try? database.setClip(id, inCategory: categoryID, isMember)
    }

    func addClip(id clipID: Int64, toCategory categoryID: Int64) {
        try? database.setClip(clipID, inCategory: categoryID, true)
    }

    @discardableResult
    func createCategory(named name: String, colorHex: String, iconKind: CategoryIconKind, iconValue: String) -> Category? {
        try? database.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
    }

    func updateCategory(_ category: Category) {
        try? database.updateCategory(category)
    }

    func deleteCategory(_ category: Category) {
        guard let id = category.id else { return }
        try? database.deleteCategory(id: id)
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

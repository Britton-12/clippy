import Foundation
import Combine
import GRDB
#if canImport(AppKit)
import AppKit
#endif

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
    /// Per-category ordered clip ID lists, keyed by categoryID.
    /// Reflects clip_category.sortOrder so category panes can present clips
    /// in user-defined order rather than global createdAt order.
    @Published private(set) var categoryClipOrder: [Int64: [Int64]] = [:]

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
        // .immediate delivers the first batch synchronously before start() returns,
        // so the panel always has data the moment it becomes visible. Subsequent
        // updates still arrive asynchronously (GRDB coalesces them).
        clipsCancellable = clipObservation.start(
            in: database.dbQueue,
            scheduling: .immediate,
            onError: { error in
                ClippyLog.error("Clip observation failed: \(error)", category: ClippyLog.storage)
            },
            onChange: { [weak self] clips in
                self?.recents = clips
            }
        )

        let categoryObservation = ValueObservation.tracking { db -> ([Category], [Int64: Set<Int64>], [Int64: [Int64]]) in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            let map = try ClipDatabase.buildMembershipMap(db)
            // Load per-category clip order from clip_category.sortOrder.
            let orderRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT categoryID, clipID
                    FROM clip_category
                    ORDER BY categoryID ASC, sortOrder ASC, addedAt DESC
                    """
            )
            var order: [Int64: [Int64]] = [:]
            for row in orderRows {
                let catID: Int64 = row["categoryID"]
                let clipID: Int64 = row["clipID"]
                order[catID, default: []].append(clipID)
            }
            return (categories, map, order)
        }
        categoriesCancellable = categoryObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                ClippyLog.error("Category observation failed: \(error)", category: ClippyLog.storage)
            },
            onChange: { [weak self] categories, map, order in
                self?.categories = categories
                self?.membership = map
                self?.categoryClipOrder = order
            }
        )
    }

    // MARK: - Memory pressure

    /// Drop the in-memory clip array back to a small resident window so the OS
    /// can reclaim the Swift heap during a critical memory-pressure event. The
    /// DB is the source of truth; the GRDB observation will repopulate `recents`
    /// on the next write (which clears the pressure anyway). Safe to call from
    /// the main thread only.
    func trimResident() {
        // Keep only the 50 most-recent clips resident; categorized clips that
        // fall outside the window will reappear on the next DB observation pulse.
        let trimLimit = 50
        if recents.count > trimLimit {
            recents = Array(recents.prefix(trimLimit))
            ClippyLog.info("trimResident: reduced resident clips to \(trimLimit)",
                           category: ClippyLog.storage)
        }
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

    /// Files a clip into `categoryID`, honoring the single-vs-multiple setting.
    /// When multiple categories are disallowed (default), the clip is first
    /// removed from every other category so it lives in exactly one.
    func fileClip(id clipID: Int64, intoCategory categoryID: Int64) {
        if !AppSettings.shared.allowMultipleCategories {
            // Mirror the removal path used by setClip(... false): clear the clip
            // from each other category before adding it to the target.
            for existing in (membership[clipID] ?? []) where existing != categoryID {
                try? database.setClip(clipID, inCategory: existing, false)
            }
        }
        addClip(id: clipID, toCategory: categoryID)
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

    /// Move one category so it sits just before another (drag-to-reorder).
    func moveCategory(id: Int64, beforeCategoryID: Int64) {
        try? database.moveCategory(id: id, before: beforeCategoryID)
    }

    /// Clips for a category in user-defined sortOrder. Uses the categoryClipOrder
    /// map so the result is instantly consistent with the live observation.
    func clipsForCategory(_ categoryID: Int64) -> [Clip] {
        // Source from `recents` (every categorized clip, unconditionally) rather
        // than `clips` (overwritten by FTS search results): otherwise an active
        // global search query makes category members that do not match the query
        // vanish from their own category pane.
        guard let orderedIDs = categoryClipOrder[categoryID] else {
            return recents.filter { membership[$0.id ?? -1]?.contains(categoryID) == true }
        }
        let clipByID = Dictionary(uniqueKeysWithValues: recents.compactMap { c -> (Int64, Clip)? in
            guard let id = c.id else { return nil }
            return (id, c)
        })
        return orderedIDs.compactMap { clipByID[$0] }
    }

    /// Move a clip to a new position within a category (drag-to-reorder).
    /// `targetClipID` is the clip the dragged one is dropped onto; pass nil to
    /// move to the end of the list.
    func moveClip(_ clipID: Int64, inCategory categoryID: Int64, before targetClipID: Int64?) {
        try? database.moveClip(clipID, inCategory: categoryID, before: targetClipID)
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        try? database.deleteClip(id: id)
    }

    func updateText(of clip: Clip, to newText: String) {
        guard let id = clip.id else { return }
        try? database.updateClipText(id: id, newText: newText)
    }

    /// Save an edited image clip: store the new PNG, repoint the row, free the
    /// old files. Returns true on success so the editor can confirm.
    @discardableResult
    func updateImage(of clip: Clip, to pngData: Data) -> Bool {
        guard let id = clip.id else { return false }
        do {
            let stored = try database.media.store(pngData: pngData)
            try database.updateClipImage(id: id, stored: stored)
            return true
        } catch {
            ClippyLog.error("failed to save edited image: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// The on-disk URL of an image clip's full-resolution PNG, for the editor.
    func imageURL(for clip: Clip) -> URL? {
        clip.mediaFilename.map { database.media.url(for: $0) }
    }

    /// Save script stdout as a new clip in history. Distinct from the capture
    /// pipeline: no deduplication, source set to "Clippy Scripts".
    @discardableResult
    func saveScriptOutput(_ text: String) -> Bool {
        do {
            try database.insertTextClip(text)
            return true
        } catch {
            ClippyLog.error("failed to save script output: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// Run OCR on an image clip, copy the result to the clipboard, and save it
    /// as a new text clip. The `completion` block is always called on the main
    /// queue and carries a human-readable outcome message for display.
    func extractText(from clip: Clip, completion: @escaping (String) -> Void) {
        guard clip.contentKind == .image,
              let filename = clip.mediaFilename else {
            completion("No image data for this clip.")
            return
        }
        let imageURL = database.media.url(for: filename)
        OCRService.recognizeText(in: imageURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text) where text.isEmpty:
                completion("No text found in image.")
            case .success(let text):
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
                do {
                    try self.database.insertTextClip(text, sourceAppName: "Clippy OCR")
                    completion("Text extracted and copied to clipboard.")
                } catch {
                    ClippyLog.error("OCR insert failed: \(error)", category: ClippyLog.storage)
                    // Clipboard copy succeeded even if the save did not.
                    completion("Text copied to clipboard (save failed).")
                }
            case .failure(let error):
                ClippyLog.error("OCR recognition failed: \(error)", category: ClippyLog.storage)
                completion("Text extraction failed: \(error.localizedDescription)")
            }
        }
    }

    func renameClip(_ clip: Clip, userTitle: String?) {
        guard let id = clip.id else { return }
        // Treat empty string the same as nil (clear the custom title).
        let trimmed = userTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        try? database.updateClipTitle(id: id, userTitle: trimmed?.isEmpty == true ? nil : trimmed)
    }

    /// The first category this clip belongs to, ordered by (sortOrder, createdAt).
    /// Used to pick the icon and accent color for pinned cards.
    func firstCategory(for clip: Clip) -> Category? {
        let ids = categoryIDs(for: clip)
        return categories.first { $0.id.map { ids.contains($0) } ?? false }
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

import Foundation
import GRDB

/// All persistence. SQLite via GRDB, with an FTS5 index kept in sync with the
/// clips table for full-text search. Unencrypted for milestone 1; SQLCipher
/// swaps in behind this same interface later.
final class ClipDatabase {
    static let shared: ClipDatabase = {
        do {
            return try ClipDatabase()
        } catch {
            fatalError("Clippy could not open its database: \(error)")
        }
    }()

    let dbQueue: DatabaseQueue
    let databaseURL: URL

    init(databaseURL: URL? = nil) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clippy", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            self.databaseURL = supportDir.appendingPathComponent("clippy.sqlite")
        }
        dbQueue = try DatabaseQueue(path: self.databaseURL.path)
        try Self.makeMigrator().migrate(dbQueue)
    }

    /// Static so tests can run migrations stepwise without building a full ClipDatabase.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentText", .text).notNull()
                t.column("contentRTF", .blob)
                t.column("contentHTML", .blob)
                t.column("typeIdentifier", .text).notNull()
                t.column("sourceAppBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "clips", columns: ["createdAt"])
            try db.create(virtualTable: "clips_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clips")
                t.tokenizer = .unicode61()
                t.column("contentText")
            }
        }
        migrator.registerMigration("v2-categories") { db in
            try db.create(table: "category") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("iconKind", .text).notNull()
                t.column("iconValue", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isStarter", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "clip_category") { t in
                t.column("clipID", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                t.column("categoryID", .integer).notNull()
                    .references("category", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["clipID", "categoryID"])
            }
            // Starter category receives every legacy pinned clip so nothing
            // is lost; users can rename or restyle it later.
            try db.execute(
                sql: """
                    INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                    VALUES ('Pinned', '#FF9500', 'symbol', 'pin.fill', 0, 1, ?)
                    """,
                arguments: [Date()]
            )
            let starterID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO clip_category (clipID, categoryID, addedAt)
                    SELECT id, ?, ? FROM clips WHERE isPinned = 1
                    """,
                arguments: [starterID, Date()]
            )
            try db.alter(table: "clips") { t in
                t.drop(column: "isPinned")
            }
        }
        return migrator
    }

    // MARK: - Writes

    /// Insert a freshly captured clip. A duplicate of an existing clip is not
    /// re-inserted; its timestamp is bumped so it surfaces at the top.
    func saveCapturedClip(_ clip: inout Clip) throws {
        let cap = AppSettings.shared.maxHistoryItems
        let newClip = clip
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("contentText") == newClip.contentText)
                .fetchOne(db)
            {
                existing.createdAt = newClip.createdAt
                existing.sourceAppBundleID = newClip.sourceAppBundleID
                existing.sourceAppName = newClip.sourceAppName
                try existing.update(db)
                return
            }
            var inserting = newClip
            try inserting.insert(db)
            try Self.evictOverCap(db, cap: cap)
        }
    }

    /// Deletes uncategorized clips beyond the cap, oldest first. Clips in any
    /// category never count against the cap.
    @discardableResult
    static func evictOverCap(_ db: Database, cap: Int) throws -> [String] {
        guard cap > 0 else { return [] }
        try db.execute(
            sql: """
                DELETE FROM clips
                WHERE id NOT IN (SELECT clipID FROM clip_category)
                AND id NOT IN (
                    SELECT id FROM clips
                    WHERE id NOT IN (SELECT clipID FROM clip_category)
                    ORDER BY createdAt DESC, id DESC
                    LIMIT ?
                )
                """,
            arguments: [cap]
        )
        return []
    }

    /// User edited the text in the plain-text editor. The original rich blobs
    /// no longer match the text, so they are dropped on purpose.
    func updateClipText(id: Int64, newText: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE clips
                    SET contentText = ?, contentRTF = NULL, contentHTML = NULL,
                        typeIdentifier = 'public.utf8-plain-text'
                    WHERE id = ?
                    """,
                arguments: [newText, id]
            )
        }
    }

    func deleteClip(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Clip.deleteOne(db, key: id)
        }
    }

    func deleteUnclassifiedClips() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)")
        }
    }

    // MARK: - Reads

    func allClips() throws -> [Clip] {
        try dbQueue.read { db in
            try Clip.order(Column("createdAt").desc, Column("id").desc).fetchAll(db)
        }
    }

    func searchClips(matching query: String, limit: Int) throws -> [Clip] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try dbQueue.read { db in
            try Clip.fetchAll(
                db,
                sql: """
                    SELECT clips.* FROM clips
                    JOIN clips_fts ON clips_fts.rowid = clips.id
                    WHERE clips_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
        }
    }

    // MARK: - Categories

    func categories() throws -> [Category] {
        try dbQueue.read { db in
            try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        }
    }

    func starterCategory() throws -> Category? {
        try dbQueue.read { db in
            try Category.filter(Column("isStarter") == true).fetchOne(db)
        }
    }

    @discardableResult
    func createCategory(
        named name: String,
        colorHex: String,
        iconKind: CategoryIconKind,
        iconValue: String
    ) throws -> Category {
        try dbQueue.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortOrder), -1) FROM category") ?? -1
            var category = Category(
                id: nil,
                name: name,
                colorHex: colorHex,
                iconKind: iconKind,
                iconValue: iconValue,
                sortOrder: maxOrder + 1,
                isStarter: false,
                createdAt: Date()
            )
            try category.insert(db)
            return category
        }
    }

    func updateCategory(_ category: Category) throws {
        try dbQueue.write { db in
            try category.update(db)
        }
    }

    func deleteCategory(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Category.deleteOne(db, key: id)
        }
    }

    func setClip(_ clipID: Int64, inCategory categoryID: Int64, _ isMember: Bool) throws {
        try dbQueue.write { db in
            if isMember {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)",
                    arguments: [clipID, categoryID, Date()]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?",
                    arguments: [clipID, categoryID]
                )
            }
        }
    }

    /// Cmd+P fast path: one keystroke toggles membership in the starter category.
    func toggleStarterMembership(clipID: Int64) throws {
        guard let starterID = try starterCategory()?.id else { return }
        let isMember = try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM clip_category WHERE clipID = ? AND categoryID = ?)",
                arguments: [clipID, starterID]
            ) ?? false
        }
        try setClip(clipID, inCategory: starterID, !isMember)
    }

    /// clipID -> set of category IDs, for fast pinned/membership lookups in views.
    func membershipMap() throws -> [Int64: Set<Int64>] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
            var map: [Int64: Set<Int64>] = [:]
            for row in rows {
                map[row["clipID"], default: []].insert(row["categoryID"])
            }
            return map
        }
    }
}

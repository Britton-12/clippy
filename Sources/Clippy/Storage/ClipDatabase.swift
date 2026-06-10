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
            if cap > 0 {
                try db.execute(
                    sql: """
                        DELETE FROM clips
                        WHERE isPinned = 0
                        AND id NOT IN (
                            SELECT id FROM clips
                            WHERE isPinned = 0
                            ORDER BY createdAt DESC, id DESC
                            LIMIT ?
                        )
                        """,
                    arguments: [cap]
                )
            }
        }
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

    func togglePin(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clips SET isPinned = NOT isPinned WHERE id = ?", arguments: [id])
        }
    }

    func deleteClip(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Clip.deleteOne(db, key: id)
        }
    }

    func deleteUnpinnedClips() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE isPinned = 0")
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
                    ORDER BY clips.isPinned DESC, rank
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
        }
    }
}

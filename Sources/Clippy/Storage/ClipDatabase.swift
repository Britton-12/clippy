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
    let media: MediaStore

    init(databaseURL: URL? = nil, mediaDirectory: URL? = nil) throws {
        if let databaseURL, let mediaDirectory {
            self.databaseURL = databaseURL
            self.media = try MediaStore(directory: mediaDirectory)
        } else {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clippy", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            self.databaseURL = databaseURL ?? supportDir.appendingPathComponent("clippy.sqlite")
            self.media = try MediaStore(
                directory: mediaDirectory ?? supportDir.appendingPathComponent("media", isDirectory: true)
            )
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
            try db.create(indexOn: "clip_category", columns: ["clipID"])
            // At most one starter category, enforced by the schema.
            try db.execute(
                sql: "CREATE UNIQUE INDEX category_single_starter ON category (isStarter) WHERE isStarter = 1"
            )
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
        migrator.registerMigration("v3-image-clips") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "contentKind", .text).notNull().defaults(to: "text")
                t.add(column: "mediaFilename", .text)
                t.add(column: "thumbFilename", .text)
                t.add(column: "pixelWidth", .integer)
                t.add(column: "pixelHeight", .integer)
                t.add(column: "byteSize", .integer)
            }
        }
        return migrator
    }

    // MARK: - Writes

    /// Insert a freshly captured clip. A duplicate of an existing clip is not
    /// re-inserted; its timestamp is bumped so it surfaces at the top.
    func saveCapturedClip(_ clip: inout Clip, cap: Int = AppSettings.shared.maxHistoryItems) throws {
        let newClip = clip
        var evicted: [String] = []
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("contentText") == newClip.contentText)
                .filter(Column("contentKind") == ClipContentKind.text.rawValue)
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
            evicted = try Self.evictOverCap(db, cap: cap)
        }
        media.delete(filenames: evicted)
    }

    /// Insert a captured image clip. Media files are written by MediaStore
    /// BEFORE this runs. Dedupe key is the content-hash filename; a re-copy
    /// bumps the timestamp.
    func saveCapturedImageClip(_ clip: inout Clip, cap: Int = AppSettings.shared.maxHistoryItems) throws {
        let newClip = clip
        var evicted: [String] = []
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("mediaFilename") == newClip.mediaFilename)
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
            evicted = try Self.evictOverCap(db, cap: cap)
        }
        media.delete(filenames: evicted)
    }

    /// Deletes uncategorized clips beyond the cap, oldest first, and returns
    /// the media filenames of evicted image clips so callers can remove files.
    /// Clips in any category never count against the cap.
    @discardableResult
    static func evictOverCap(_ db: Database, cap: Int) throws -> [String] {
        guard cap > 0 else { return [] }
        let doomedSQL = """
            SELECT id FROM clips
            WHERE id NOT IN (SELECT clipID FROM clip_category)
            AND id NOT IN (
                SELECT id FROM clips
                WHERE id NOT IN (SELECT clipID FROM clip_category)
                ORDER BY createdAt DESC, id DESC
                LIMIT \(cap)
            )
            """
        let filenames = try String.fetchAll(
            db,
            sql: """
                SELECT mediaFilename FROM clips
                WHERE mediaFilename IS NOT NULL AND id IN (\(doomedSQL))
                UNION ALL
                SELECT thumbFilename FROM clips
                WHERE thumbFilename IS NOT NULL AND id IN (\(doomedSQL))
                """
        )
        try db.execute(sql: "DELETE FROM clips WHERE id IN (\(doomedSQL))")
        return filenames
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
        let filenames: [String] = try dbQueue.write { db in
            let clip = try Clip.fetchOne(db, key: id)
            try Clip.deleteOne(db, key: id)
            return clip?.mediaFilenames ?? []
        }
        media.delete(filenames: filenames)
    }

    func deleteUnclassifiedClips() throws {
        let filenames: [String] = try dbQueue.write { db in
            let doomed = try Clip
                .filter(sql: "id NOT IN (SELECT clipID FROM clip_category)")
                .fetchAll(db)
            try db.execute(sql: "DELETE FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)")
            return doomed.flatMap(\.mediaFilenames)
        }
        media.delete(filenames: filenames)
    }

    /// Every media filename any clip references, for the launch orphan sweep.
    func referencedMediaFilenames() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT mediaFilename, thumbFilename FROM clips WHERE mediaFilename IS NOT NULL OR thumbFilename IS NOT NULL"
            )
            var names = Set<String>()
            for row in rows {
                if let m: String = row["mediaFilename"] { names.insert(m) }
                if let t: String = row["thumbFilename"] { names.insert(t) }
            }
            return names
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

    // MARK: - Category state

    /// Cached after first lookup: the starter category is created in migration
    /// v2 and never deleted, so its id is stable for the process lifetime.
    /// Stored here because extensions cannot declare stored properties; the
    /// category API lives in ClipDatabase+Categories.swift.
    var cachedStarterCategoryID: Int64?
}

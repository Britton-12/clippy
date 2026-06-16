import XCTest
import GRDB
@testable import Clippy

// MARK: - DB-level reorder contract tests

/// Verifies that moveCategory and moveClip write gap-free, 0-based sortOrder
/// values that survive a fresh read from the database. Each test opens an
/// isolated temp database via makeTestDatabase, mutates it, then RE-READS
/// from the same DatabaseQueue using the same public API (categories() /
/// clipsForCategory()) to confirm persistence -- not an in-memory cache.
final class ClipDatabaseReorderTests: XCTestCase {

    // MARK: - Helpers

    /// Insert a non-starter category directly and return it with its assigned id.
    private func insertCategory(
        _ db: ClipDatabase,
        name: String,
        sortOrder: Int
    ) throws -> Clippy.Category {
        return try db.dbQueue.write { grdb in
            var cat = Clippy.Category(
                id: nil,
                name: name,
                colorHex: "#000000",
                iconKind: .symbol,
                iconValue: "circle",
                sortOrder: sortOrder,
                isStarter: false,
                createdAt: Date()
            )
            try cat.insert(grdb)
            return cat // id is set via didInsert
        }
    }

    /// Insert a text clip directly and return it with its assigned id.
    private func insertClip(
        _ db: ClipDatabase,
        text: String,
        createdAt: Date = Date()
    ) throws -> Clip {
        return try db.dbQueue.write { grdb in
            var clip = makeTextClip(text, createdAt: createdAt)
            try clip.insert(grdb) // didInsert sets clip.id
            return clip
        }
    }

    // MARK: - moveCategory

    /// After moving a category, a fresh read via categories() must return all
    /// categories (starter included) in the new order with sortOrder 0..n-1.
    func testMoveCategoryPersistsSortOrder() throws {
        let db = try makeTestDatabase(self)

        // The migration inserts a starter category at sortOrder 0.
        // Insert three more categories that will get sortOrders 0, 1, 2 in the
        // category table (they are non-starter, so they can share 0-based values
        // independently; moveCategory renumbers ALL categories together).
        let a = try insertCategory(db, name: "Alpha", sortOrder: 1)
        _ = try insertCategory(db, name: "Beta",  sortOrder: 2)
        let c = try insertCategory(db, name: "Gamma", sortOrder: 3)

        // Move Gamma before Alpha: among non-starter categories the expected
        // visual order becomes Gamma, Alpha, Beta.
        try db.moveCategory(id: c.id!, before: a.id!)

        // RE-READ all categories from the database (not a cache).
        let all = try db.categories()

        // sortOrder values across all categories must be exactly 0..<total.
        let allOrders = all.map { $0.sortOrder }
        XCTAssertEqual(allOrders, Array(0..<all.count),
                       "persisted sortOrder values must be gap-free 0-based integers across all categories")

        // The non-starter subset must appear in the new visual order.
        let nonStarter = all.filter { !$0.isStarter }.map { $0.name }
        XCTAssertEqual(nonStarter, ["Gamma", "Alpha", "Beta"],
                       "non-starter categories must be persisted in the new visual order")

        // No element must be lost (permutation invariant).
        XCTAssertEqual(Set(nonStarter), Set(["Alpha", "Beta", "Gamma"]),
                       "all categories must survive the reorder")
    }

    /// Absent target ID causes append-to-end, which must also produce
    /// gap-free 0-based sortOrder across all categories.
    func testMoveCategoryToEndPersistsSortOrder() throws {
        let db = try makeTestDatabase(self)

        let a = try insertCategory(db, name: "Alpha", sortOrder: 1)
        _ = try insertCategory(db, name: "Beta",  sortOrder: 2)
        _ = try insertCategory(db, name: "Gamma", sortOrder: 3)

        // 99999 is not a real ID; reorderIDs treats it as absent and appends.
        try db.moveCategory(id: a.id!, before: 99999)

        let all = try db.categories()
        let allOrders = all.map { $0.sortOrder }
        XCTAssertEqual(allOrders, Array(0..<all.count),
                       "persisted sortOrder values must be gap-free 0-based integers after append")

        let nonStarter = all.filter { !$0.isStarter }.map { $0.name }
        XCTAssertEqual(nonStarter, ["Beta", "Gamma", "Alpha"],
                       "absent target must append the category to the end of the non-starter list")
    }

    // MARK: - moveClip

    /// After moving a clip within a category, a fresh read via clipsForCategory
    /// must return clips in the new order. The raw sortOrder values in the
    /// clip_category junction table are verified directly to confirm persistence.
    func testMoveClipPersistsSortOrder() throws {
        let db = try makeTestDatabase(self)

        let cat = try insertCategory(db, name: "Work", sortOrder: 1)
        let catID = cat.id!

        // Insert clips directly to get their ids (saveCapturedClip does not
        // propagate the inserted id back through the inout parameter).
        let clip1 = try insertClip(db, text: "first",  createdAt: Date(timeIntervalSinceNow: -30))
        let clip2 = try insertClip(db, text: "second", createdAt: Date(timeIntervalSinceNow: -20))
        let clip3 = try insertClip(db, text: "third",  createdAt: Date(timeIntervalSinceNow: -10))
        let id1 = clip1.id!
        let id2 = clip2.id!
        let id3 = clip3.id!

        // Add clips to the category and stamp an explicit 0-based sortOrder so the
        // baseline order (first=0, second=1, third=2) is deterministic.
        try db.setClip(id1, inCategory: catID, true)
        try db.setClip(id2, inCategory: catID, true)
        try db.setClip(id3, inCategory: catID, true)

        try db.dbQueue.write { grdb in
            try grdb.execute(
                sql: "UPDATE clip_category SET sortOrder = ? WHERE clipID = ? AND categoryID = ?",
                arguments: [0, id1, catID])
            try grdb.execute(
                sql: "UPDATE clip_category SET sortOrder = ? WHERE clipID = ? AND categoryID = ?",
                arguments: [1, id2, catID])
            try grdb.execute(
                sql: "UPDATE clip_category SET sortOrder = ? WHERE clipID = ? AND categoryID = ?",
                arguments: [2, id3, catID])
        }

        // Move "third" before "first": expected order -> third, first, second.
        try db.moveClip(id3, inCategory: catID, before: id1)

        // RE-READ via the public query path (not a cache).
        let reloaded = try db.clipsForCategory(catID)
        let texts = reloaded.map { $0.contentText }
        XCTAssertEqual(texts, ["third", "first", "second"],
                       "clips must be persisted in the new visual order")

        // Verify the raw junction-table sortOrder values are gap-free 0-based.
        // This proves what was written to disk, independently of clipsForCategory.
        let rawOrders: [Int] = try db.dbQueue.read { grdb in
            let rows = try Row.fetchAll(
                grdb,
                sql: """
                    SELECT sortOrder FROM clip_category
                    WHERE categoryID = ?
                    ORDER BY sortOrder ASC
                    """,
                arguments: [catID]
            )
            return rows.map { $0["sortOrder"] }
        }
        XCTAssertEqual(rawOrders, Array(0..<reloaded.count),
                       "raw junction-table sortOrder values must be gap-free 0-based integers")

        // Permutation invariant: no clip was lost.
        XCTAssertEqual(Set(texts), Set(["first", "second", "third"]),
                       "all clips must survive the reorder")
    }

    /// Nil target moves the clip to the end. Verifies the append path persists
    /// correct sortOrder values and the right visual order.
    func testMoveClipToEndPersistsSortOrder() throws {
        let db = try makeTestDatabase(self)

        let cat = try insertCategory(db, name: "Personal", sortOrder: 1)
        let catID = cat.id!

        let clip1 = try insertClip(db, text: "alpha", createdAt: Date(timeIntervalSinceNow: -30))
        let clip2 = try insertClip(db, text: "beta",  createdAt: Date(timeIntervalSinceNow: -20))
        let clip3 = try insertClip(db, text: "gamma", createdAt: Date(timeIntervalSinceNow: -10))
        let id1 = clip1.id!
        let id2 = clip2.id!
        let id3 = clip3.id!

        try db.setClip(id1, inCategory: catID, true)
        try db.setClip(id2, inCategory: catID, true)
        try db.setClip(id3, inCategory: catID, true)

        try db.dbQueue.write { grdb in
            try grdb.execute(
                sql: "UPDATE clip_category SET sortOrder = ? WHERE clipID = ? AND categoryID = ?",
                arguments: [0, id1, catID])
            try grdb.execute(
                sql: "UPDATE clip_category SET sortOrder = ? WHERE clipID = ? AND categoryID = ?",
                arguments: [1, id2, catID])
            try grdb.execute(
                sql: "UPDATE clip_category SET sortOrder = ? WHERE clipID = ? AND categoryID = ?",
                arguments: [2, id3, catID])
        }

        // Move "alpha" to the end via nil target.
        try db.moveClip(id1, inCategory: catID, before: nil)

        let reloaded = try db.clipsForCategory(catID)
        let texts = reloaded.map { $0.contentText }
        XCTAssertEqual(texts, ["beta", "gamma", "alpha"],
                       "nil target must append clip to the end of the category")

        let rawOrders: [Int] = try db.dbQueue.read { grdb in
            let rows = try Row.fetchAll(
                grdb,
                sql: """
                    SELECT sortOrder FROM clip_category
                    WHERE categoryID = ?
                    ORDER BY sortOrder ASC
                    """,
                arguments: [catID]
            )
            return rows.map { $0["sortOrder"] }
        }
        XCTAssertEqual(rawOrders, Array(0..<reloaded.count),
                       "raw sortOrder values must be gap-free after append move")
    }
}

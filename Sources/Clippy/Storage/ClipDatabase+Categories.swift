import Foundation
import GRDB

// MARK: - Categories

extension ClipDatabase {
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

    /// Cached after first lookup: the starter category is created in migration
    /// v2 and never deleted, so its id is stable for the process lifetime.
    func starterCategoryID() throws -> Int64? {
        if let cachedStarterCategoryID { return cachedStarterCategoryID }
        cachedStarterCategoryID = try starterCategory()?.id
        return cachedStarterCategoryID
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
        // Drop the cache if the starter itself was deleted so Cmd+P recreates it.
        if id == cachedStarterCategoryID { cachedStarterCategoryID = nil }
    }

    /// Reorder: place `id` immediately before `targetID`, then renumber every
    /// category's sortOrder sequentially so the order is stable and gap-free.
    func moveCategory(id: Int64, before targetID: Int64) throws {
        try dbQueue.write { db in
            var cats = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            guard let fromIndex = cats.firstIndex(where: { $0.id == id }) else { return }
            let moving = cats.remove(at: fromIndex)
            // Recompute the target index after the removal shifts things.
            let insertIndex = cats.firstIndex(where: { $0.id == targetID }) ?? cats.count
            cats.insert(moving, at: insertIndex)
            for (index, category) in cats.enumerated() where category.sortOrder != index {
                var updated = category
                updated.sortOrder = index
                try updated.update(db)
            }
        }
    }

    /// Recreate the starter ("Pinned") category if the user deleted it, so the
    /// Cmd+P pin shortcut always has a home to toggle.
    private func ensureStarterCategoryID() throws -> Int64? {
        if let id = try starterCategoryID() { return id }
        let created = try dbQueue.write { db -> Int64? in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortOrder), -1) FROM category") ?? -1
            var category = Category(
                id: nil, name: "Pinned", colorHex: "#FF9500",
                iconKind: .symbol, iconValue: "pin.fill",
                sortOrder: maxOrder + 1, isStarter: true, createdAt: Date()
            )
            try category.insert(db)
            return category.id
        }
        cachedStarterCategoryID = created
        return created
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
        guard let starterID = try ensureStarterCategoryID() else { return }
        try dbQueue.write { db in
            let isMember = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM clip_category WHERE clipID = ? AND categoryID = ?)",
                arguments: [clipID, starterID]
            ) ?? false
            if isMember {
                try db.execute(
                    sql: "DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?",
                    arguments: [clipID, starterID]
                )
            } else {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)",
                    arguments: [clipID, starterID, Date()]
                )
            }
        }
    }

    /// clipID -> set of category IDs, for fast pinned/membership lookups in views.
    // Whole-table load is bounded in practice: uncategorized clips are capped
    // and categorized clips are user-curated.
    func membershipMap() throws -> [Int64: Set<Int64>] {
        try dbQueue.read { try Self.buildMembershipMap($0) }
    }

    /// The single clipID -> categoryID fold. `static` so the `ValueObservation`
    /// closure in ClipStore can call it without capturing a `ClipDatabase`.
    static func buildMembershipMap(_ db: Database) throws -> [Int64: Set<Int64>] {
        let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
        var map: [Int64: Set<Int64>] = [:]
        for row in rows {
            map[row["clipID"], default: []].insert(row["categoryID"])
        }
        return map
    }
}

import XCTest
import GRDB
@testable import Clippy

final class CategoryTests: XCTestCase {
    func testMigrationCreatesStarterCategory() throws {
        let db = try makeTestDatabase(self)
        let starter = try db.starterCategory()
        XCTAssertEqual(starter?.name, "Pinned")
        XCTAssertTrue(starter?.isStarter == true)
    }

    func testLegacyPinnedClipsMigrateToStarterCategory() throws {
        // Build a v1 database by hand, mark a clip pinned, then run the
        // full migrator over it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, isPinned)
                    VALUES ('keep me', 'public.utf8-plain-text', ?, 1),
                           ('plain', 'public.utf8-plain-text', ?, 0)
                    """,
                arguments: [Date(), Date()]
            )
        }

        let migrated = try ClipDatabase(databaseURL: url)
        let starterID = try XCTUnwrap(migrated.starterCategory()?.id)
        let map = try migrated.membershipMap()
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.values.first, [starterID])
    }

    func testCategoryCRUDAndMembership() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("snippet")
        try db.saveCapturedClip(&clip)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        let work = try db.createCategory(
            named: "Work", colorHex: "#007AFF", iconKind: .symbol, iconValue: "briefcase.fill"
        )
        let workID = try XCTUnwrap(work.id)

        try db.setClip(clipID, inCategory: workID, true)
        XCTAssertEqual(try db.membershipMap()[clipID], [workID])

        var renamed = work
        renamed.name = "Job"
        try db.updateCategory(renamed)
        XCTAssertEqual(try db.categories().first(where: { $0.id == workID })?.name, "Job")

        // Deleting a category never deletes clips; junction rows cascade away.
        try db.deleteCategory(id: workID)
        XCTAssertNil(try db.membershipMap()[clipID])
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testToggleStarterMembership() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("pin me")
        try db.saveCapturedClip(&clip)
        let clipID = try XCTUnwrap(db.allClips().first?.id)
        let starterID = try XCTUnwrap(db.starterCategory()?.id)

        try db.toggleStarterMembership(clipID: clipID)
        XCTAssertEqual(try db.membershipMap()[clipID], [starterID])
        try db.toggleStarterMembership(clipID: clipID)
        XCTAssertNil(try db.membershipMap()[clipID])
    }
}

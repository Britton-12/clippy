import XCTest
@testable import Clippy

final class EvictionTests: XCTestCase {
    /// Categorized clips are exempt from the history cap.
    func testCapEvictionSkipsCategorizedClips() throws {
        let db = try makeTestDatabase(self)
        let savedCap = AppSettings.shared.maxHistoryItems
        AppSettings.shared.maxHistoryItems = 2
        addTeardownBlock { AppSettings.shared.maxHistoryItems = savedCap }

        var old = makeTextClip("oldest", createdAt: Date(timeIntervalSinceNow: -300))
        try db.saveCapturedClip(&old)
        let oldID = try XCTUnwrap(db.allClips().first?.id)
        try db.toggleStarterMembership(clipID: oldID)

        for i in 0..<3 {
            var clip = makeTextClip("clip-\(i)", createdAt: Date(timeIntervalSinceNow: Double(i - 3)))
            try db.saveCapturedClip(&clip)
        }

        let texts = try db.allClips().map(\.contentText)
        XCTAssertTrue(texts.contains("oldest"), "categorized clip must survive the cap")
        XCTAssertEqual(texts.count, 3) // 2 uncategorized + 1 categorized
    }

    func testDeleteUnclassifiedKeepsCategorized() throws {
        let db = try makeTestDatabase(self)
        var keep = makeTextClip("keep")
        try db.saveCapturedClip(&keep)
        var drop = makeTextClip("drop")
        try db.saveCapturedClip(&drop)
        let keepID = try XCTUnwrap(db.allClips().first(where: { $0.contentText == "keep" })?.id)
        try db.toggleStarterMembership(clipID: keepID)

        try db.deleteUnclassifiedClips()
        XCTAssertEqual(try db.allClips().map(\.contentText), ["keep"])
    }
}

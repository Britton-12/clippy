import XCTest
@testable import Clippy

final class ClipDatabaseTests: XCTestCase {
    func testOpensAtInjectedURL() throws {
        let db = try makeTestDatabase(self)
        XCTAssertTrue(db.databaseURL.path.contains("clippy-tests-"))
        var clip = makeTextClip("hello")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        XCTAssertEqual(try db.allClips().count, 1)
    }
}

import XCTest
@testable import Clippy

final class ClipSearchQueryTests: XCTestCase {
    // Fixed reference instant so relative-date math is deterministic.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var cal: Calendar { Calendar(identifier: .gregorian) }

    // MARK: - Parser

    func testEmptyQueryIsEmpty() {
        let p = ClipQueryParser.parse("   ", now: now, calendar: cal)
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.text, "")
        XCTAssertTrue(p.sourceApps.isEmpty)
        XCTAssertNil(p.since)
    }

    func testPlainTextOnly() {
        let p = ClipQueryParser.parse("quarterly invoice", now: now, calendar: cal)
        XCTAssertEqual(p.text, "quarterly invoice")
        XCTAssertTrue(p.sourceApps.isEmpty)
        XCTAssertNil(p.since)
    }

    func testAppTokenOnly() {
        let p = ClipQueryParser.parse("#edge", now: now, calendar: cal)
        XCTAssertEqual(p.sourceApps, ["edge"])
        XCTAssertEqual(p.text, "")
        XCTAssertNil(p.since)
    }

    func testDurationTokenWeeks() {
        let p = ClipQueryParser.parse("#2weeks", now: now, calendar: cal)
        let expected = cal.date(byAdding: .weekOfYear, value: -2, to: now)!
        XCTAssertEqual(p.since!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(p.sourceApps.isEmpty)
    }

    func testCombinedTextAppDuration() {
        let p = ClipQueryParser.parse("invoice #edge #2weeks", now: now, calendar: cal)
        XCTAssertEqual(p.text, "invoice")
        XCTAssertEqual(p.sourceApps, ["edge"])
        XCTAssertEqual(p.since!.timeIntervalSince1970,
                       cal.date(byAdding: .weekOfYear, value: -2, to: now)!.timeIntervalSince1970,
                       accuracy: 1)
    }

    func testTodayAndYesterday() {
        XCTAssertEqual(ClipQueryParser.parse("#today", now: now, calendar: cal).since,
                       cal.startOfDay(for: now))
        let y = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        XCTAssertEqual(ClipQueryParser.parse("#yesterday", now: now, calendar: cal).since, y)
    }

    func testShortFormsAndDefaultCount() {
        XCTAssertEqual(ClipQueryParser.parse("#3d", now: now, calendar: cal).since!.timeIntervalSince1970,
                       cal.date(byAdding: .day, value: -3, to: now)!.timeIntervalSince1970, accuracy: 1)
        // Bare unit means count 1.
        XCTAssertEqual(ClipQueryParser.parse("#month", now: now, calendar: cal).since!.timeIntervalSince1970,
                       cal.date(byAdding: .month, value: -1, to: now)!.timeIntervalSince1970, accuracy: 1)
    }

    func testUnknownUnitTreatedAsApp() {
        // "#5x" is not a recognized duration, so it is an app filter, not a date.
        let p = ClipQueryParser.parse("#5x", now: now, calendar: cal)
        XCTAssertEqual(p.sourceApps, ["5x"])
        XCTAssertNil(p.since)
    }

    func testMultipleDurationsKeepWidestWindow() {
        // Earliest (widest) lower bound wins.
        let p = ClipQueryParser.parse("#2d #3weeks", now: now, calendar: cal)
        XCTAssertEqual(p.since!.timeIntervalSince1970,
                       cal.date(byAdding: .weekOfYear, value: -3, to: now)!.timeIntervalSince1970,
                       accuracy: 1)
    }

    // MARK: - DB-backed search (the SQL actually filters)

    func testSearchFiltersBySourceApp() throws {
        let db = try makeTestDatabase(self)
        var edge = makeTextClip("alpha receipt")
        edge.sourceAppName = "Microsoft Edge"
        edge.sourceAppBundleID = "com.microsoft.edgemac"
        var other = makeTextClip("beta receipt")
        other.sourceAppName = "Notes"
        other.sourceAppBundleID = "com.apple.notes"
        try db.saveCapturedClip(&edge, cap: 1000)
        try db.saveCapturedClip(&other, cap: 1000)

        let results = try db.searchClips(matching: "#edge", limit: 50)
        XCTAssertEqual(results.map(\.sourceAppName), ["Microsoft Edge"])
    }

    func testSearchFiltersByDuration() throws {
        let db = try makeTestDatabase(self)
        var recent = makeTextClip("fresh", createdAt: Date())
        var old = makeTextClip("stale", createdAt: Date().addingTimeInterval(-20 * 24 * 3600))
        try db.saveCapturedClip(&recent, cap: 1000)
        try db.saveCapturedClip(&old, cap: 1000)

        let results = try db.searchClips(matching: "#2weeks", limit: 50)
        let texts = results.map(\.contentText)
        XCTAssertTrue(texts.contains("fresh"))
        XCTAssertFalse(texts.contains("stale"))
    }

    func testSearchCombinesAppAndText() throws {
        let db = try makeTestDatabase(self)
        var edgeInvoice = makeTextClip("invoice march")
        edgeInvoice.sourceAppName = "Microsoft Edge"
        var edgeOther = makeTextClip("recipe ideas")
        edgeOther.sourceAppName = "Microsoft Edge"
        try db.saveCapturedClip(&edgeInvoice, cap: 1000)
        try db.saveCapturedClip(&edgeOther, cap: 1000)

        let results = try db.searchClips(matching: "invoice #edge", limit: 50)
        XCTAssertEqual(results.map(\.contentText), ["invoice march"])
    }
}

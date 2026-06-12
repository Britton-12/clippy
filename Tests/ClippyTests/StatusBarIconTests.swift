import XCTest
import AppKit
@testable import Clippy

final class StatusBarIconTests: XCTestCase {

    func testImageIsTemplate() {
        XCTAssertTrue(StatusBarIcon.image().isTemplate)
        XCTAssertTrue(StatusBarIcon.image(paused: true).isTemplate)
    }

    func testImageRendersNonEmptyBitmap() {
        XCTAssertNotNil(StatusBarIcon.image().tiffRepresentation)
        XCTAssertGreaterThan(StatusBarIcon.image().tiffRepresentation?.count ?? 0, 0)
    }

    func testPausedAndActiveDiffer() {
        // Outline vs filled clipboard must be distinct glyphs.
        XCTAssertNotEqual(
            StatusBarIcon.image(paused: false).tiffRepresentation,
            StatusBarIcon.image(paused: true).tiffRepresentation
        )
    }
}

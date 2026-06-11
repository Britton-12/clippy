import XCTest
@testable import Clippy

final class SoundCatalogTests: XCTestCase {

    func testOptionsNonEmpty() {
        XCTAssertFalse(SoundCatalog.options.isEmpty)
    }

    func testDefaultIDIsAvailable() {
        XCTAssertTrue(SoundCatalog.contains(SoundCatalog.defaultID))
    }

    func testAllClassicSoundsArePresent() {
        // Every classic alert sound should be addressable as "system:<Name>".
        for sound in CaptureSound.allCases {
            XCTAssertTrue(
                SoundCatalog.contains("system:\(sound.rawValue)"),
                "catalog missing classic sound \(sound.rawValue)"
            )
        }
    }

    func testCatalogIncludesMoreThanClassics() {
        // The notification / UI sounds should expand the list well past the 14
        // classics on any standard macOS install.
        XCTAssertGreaterThan(SoundCatalog.options.count, CaptureSound.allCases.count)
    }

    func testResolvedIDFallsBackForUnknown() {
        XCTAssertEqual(SoundCatalog.resolvedID(for: "file:/does/not/exist.caf"), SoundCatalog.defaultID)
    }

    func testResolvedIDKeepsValidSelection() {
        XCTAssertEqual(SoundCatalog.resolvedID(for: "system:Tink"), "system:Tink")
    }

    func testResolveClassicIDReturnsSound() {
        XCTAssertNotNil(SoundPlayer.resolve(id: "system:Tink"))
    }

    func testPlayUnknownIDReturnsFalse() {
        XCTAssertFalse(SoundPlayer.play(id: "file:/nope.caf", volume: 0))
    }
}

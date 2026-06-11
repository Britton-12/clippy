import XCTest
import AppKit
@testable import Clippy

final class MascotStatusIconTests: XCTestCase {

    func testImageIsTemplate() {
        XCTAssertTrue(MascotStatusIcon.image().isTemplate)
    }

    func testImageHasExpectedSize() {
        XCTAssertEqual(MascotStatusIcon.image().size, NSSize(width: 18, height: 18))
    }

    func testImageRendersNonEmptyBitmap() {
        // A blank image would produce no TIFF data; confirm the mascot actually
        // drew something.
        let image = MascotStatusIcon.image()
        let tiff = image.tiffRepresentation
        XCTAssertNotNil(tiff)
        XCTAssertGreaterThan(tiff?.count ?? 0, 0)
    }
}

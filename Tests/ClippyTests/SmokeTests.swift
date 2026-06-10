import XCTest
@testable import Clippy

final class SmokeTests: XCTestCase {
    func testClipKindDetection() {
        XCTAssertEqual(ClipKind.detect("https://example.com"), .link)
        XCTAssertEqual(ClipKind.detect("plain words"), .text)
    }
}

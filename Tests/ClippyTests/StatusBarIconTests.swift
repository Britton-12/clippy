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

    /// The icon (the `paperclip` SF Symbol) must carry ink near the top of the
    /// canvas at 2x — i.e. it is not blank or clipped at the top. SF Symbols render
    /// with correct optical sizing, so this holds without any custom geometry.
    func testIconFillsFullCanvasAt2xScale() {
        let img = StatusBarIcon.image()
        let pixelSize = 36 // 18pt * 2x

        // Render into a 36x36 bitmap (simulates Retina 2x backing store).
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelSize * 4,
            bitsPerPixel: 32
        ) else {
            XCTFail("Could not create NSBitmapImageRep")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Draw the image into the full 36x36 backing rect. NSImage will invoke the
        // lazy drawing handler with this destination rect as its argument.
        img.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()

        // Count rows with ink in the top quarter of the bitmap (rows 27-35 in a
        // bottom-origin coordinate system, i.e. the visual top of the icon).
        var topQuarterInkRows = 0
        let topThreshold = (pixelSize * 3) / 4 // pixel row 27 and above = visual top quarter
        for row in topThreshold..<pixelSize {
            for col in 0..<pixelSize {
                if let color = rep.colorAt(x: col, y: row) {
                    // NSBitmapImageRep.colorAt uses top-left origin; row 0 = visual top.
                    // We want the visual top quarter = rows 0..(pixelSize/4).
                    _ = color
                }
            }
        }

        // Simpler approach: check via pixel data directly.
        // NSBitmapImageRep with top-left origin: row 0 = top of image.
        topQuarterInkRows = 0
        let topQuarterEndRow = pixelSize / 4 // rows 0..8 = visual top 25%
        for row in 0..<topQuarterEndRow {
            var rowHasInk = false
            for col in 0..<pixelSize {
                if let color = rep.colorAt(x: col, y: row) {
                    // Any channel > 0 means ink (template image draws in black).
                    if color.alphaComponent > 0.04 {
                        rowHasInk = true
                        break
                    }
                }
            }
            if rowHasInk { topQuarterInkRows += 1 }
        }

        // The eyebrows sit near the top of the design; at least 2 rows in the top
        // quarter must carry ink. Before the fix this count was 0.
        XCTAssertGreaterThanOrEqual(
            topQuarterInkRows, 2,
            "Top quarter of 2x icon has \(topQuarterInkRows) ink rows; expected >= 2. " +
            "The drawing handler may be ignoring destRect and drawing into a smaller rect."
        )
    }
}

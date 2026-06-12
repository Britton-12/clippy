import XCTest
import AppKit
@testable import Clippy

final class ImageEditingTests: XCTestCase {

    // Catalog colors (NSColor.red) cannot be written into a deviceRGB rep, so
    // tests build device colors directly.
    private let devRed = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
    private let devGreen = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
    private let devBlue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)

    private func makeBitmap(width: Int, height: Int, color: (Int, Int) -> NSColor) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<height {
            for x in 0..<width {
                rep.setColor(color(x, y), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// Read a pixel by drawing the image into a controlled RGBA buffer. This
    /// avoids NSBitmapImageRep.colorAt, which round-trips through an ambiguous
    /// colorspace and returns black here. Returns 0-1 components.
    private func pixel(_ image: NSImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double)? {
        guard let cg = ImageEditing.cgImage(image) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))),
              let data = ctx.data else { return nil }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let i = (y * w + x) * 4
        return (Double(buf[i]) / 255, Double(buf[i + 1]) / 255, Double(buf[i + 2]) / 255)
    }

    func testRotate90SwapsDimensions() throws {
        let image = makeBitmap(width: 4, height: 2) { _, _ in devRed }
        let rotated = try XCTUnwrap(ImageEditing.rotated(image, byDegrees: 90))
        XCTAssertEqual(Int(rotated.size.width), 2)
        XCTAssertEqual(Int(rotated.size.height), 4)
    }

    func testFourRotationsReturnToOriginalSize() throws {
        var image = makeBitmap(width: 4, height: 2) { _, _ in devGreen }
        for _ in 0..<4 {
            image = try XCTUnwrap(ImageEditing.rotated(image, byDegrees: 90))
        }
        XCTAssertEqual(Int(image.size.width), 4)
        XCTAssertEqual(Int(image.size.height), 2)
    }

    func testCropClampsAndResizes() throws {
        let image = makeBitmap(width: 10, height: 10) { _, _ in devBlue }
        let cropped = try XCTUnwrap(ImageEditing.cropped(image, to: CGRect(x: 1, y: 1, width: 4, height: 4)))
        XCTAssertEqual(Int(cropped.size.width), 4)
        XCTAssertEqual(Int(cropped.size.height), 4)
    }

    func testHorizontalFlipSwapsLeftAndRight() throws {
        // Left pixel red, right pixel blue. After a horizontal flip the left
        // pixel must read blue.
        let image = makeBitmap(width: 2, height: 1) { x, _ in x == 0 ? devRed : devBlue }
        let flipped = try XCTUnwrap(ImageEditing.flipped(image, horizontal: true))
        let left = try XCTUnwrap(pixel(flipped, 0, 0))
        XCTAssertGreaterThan(left.b, 0.5, "left pixel should now be the blue one")
        XCTAssertLessThan(left.r, 0.5)
    }

    func testPNGDataRoundTrips() throws {
        let image = makeBitmap(width: 3, height: 3) { _, _ in devRed }
        let data = try XCTUnwrap(ImageEditing.pngData(image))
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertNotNil(NSBitmapImageRep(data: data))
    }
}

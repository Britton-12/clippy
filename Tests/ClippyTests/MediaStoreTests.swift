import AppKit
import XCTest
@testable import Clippy

final class MediaStoreTests: XCTestCase {
    private func makeStore() throws -> MediaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-media-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try MediaStore(directory: dir)
    }

    func makePNGData(width: Int = 600, height: Int = 400) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testStoreWritesImageAndThumbnail() throws {
        let store = try makeStore()
        let stored = try store.store(pngData: makePNGData())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored.mediaFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored.thumbFilename).path))
        XCTAssertEqual(stored.pixelWidth, 600)
        XCTAssertEqual(stored.pixelHeight, 400)
    }

    func testStoreIsIdempotentForSameBytes() throws {
        let store = try makeStore()
        let data = makePNGData()
        let first = try store.store(pngData: data)
        let second = try store.store(pngData: data)
        XCTAssertEqual(first, second)
    }

    func testSweepOrphansRemovesOnlyUnreferencedFiles() throws {
        let store = try makeStore()
        let stored = try store.store(pngData: makePNGData())
        let orphanURL = store.url(for: "orphan.png")
        try Data([0x1]).write(to: orphanURL)

        store.sweepOrphans(referencedFilenames: [stored.mediaFilename, stored.thumbFilename])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored.mediaFilename).path))
    }

    func testDeleteRemovesFiles() throws {
        let store = try makeStore()
        let stored = try store.store(pngData: makePNGData())
        store.delete(filenames: [stored.mediaFilename, stored.thumbFilename])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: stored.mediaFilename).path))
    }
}

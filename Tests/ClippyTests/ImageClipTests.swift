import XCTest
@testable import Clippy

final class ImageClipTests: XCTestCase {
    private func storeImage(_ db: ClipDatabase, data: Data) throws -> Clip {
        let stored = try db.media.store(pngData: data)
        var clip = makeImageClip(stored)
        try db.saveCapturedImageClip(&clip)
        return clip
    }

    func testImageClipRoundTrip() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)

        let fetched = try XCTUnwrap(db.allClips().first)
        XCTAssertEqual(fetched.contentKind, .image)
        XCTAssertEqual(fetched.pixelWidth, 600)
        XCTAssertNotNil(fetched.mediaFilename)
    }

    func testImageDedupeBumpsTimestampInsteadOfDuplicating() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        _ = try storeImage(db, data: png)
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testDeleteClipRemovesMediaFiles() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        let clip = try XCTUnwrap(db.allClips().first)
        let mediaURL = db.media.url(for: try XCTUnwrap(clip.mediaFilename))
        let thumbURL = db.media.url(for: try XCTUnwrap(clip.thumbFilename))

        try db.deleteClip(id: try XCTUnwrap(clip.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbURL.path))
    }

    func testReferencedMediaFilenamesListsBothFiles() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        let clip = try XCTUnwrap(db.allClips().first)
        let referenced = try db.referencedMediaFilenames()
        XCTAssertEqual(referenced, [
            try XCTUnwrap(clip.mediaFilename),
            try XCTUnwrap(clip.thumbFilename),
        ])
    }

    func testCapEvictionRemovesMediaFiles() throws {
        let db = try makeTestDatabase(self)

        let png = MediaStoreTests().makePNGData()
        let stored = try db.media.store(pngData: png)
        var imageClip = makeImageClip(stored, createdAt: Date(timeIntervalSinceNow: -60))
        try db.saveCapturedImageClip(&imageClip, cap: 1)

        var newer = makeTextClip("newer")
        try db.saveCapturedClip(&newer, cap: 1)

        XCTAssertEqual(try db.allClips().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.media.url(for: stored.mediaFilename).path))
    }
}

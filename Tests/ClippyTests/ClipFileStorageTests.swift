import XCTest
@testable import Clippy

/// Headless verification of the file-clip storage path (feature C): MediaStore
/// byte copy, saveCapturedFileClip persistence, the reference-only path, and dedup.
/// The capture trigger (NSPasteboard file URLs) and paste/move keystrokes are
/// GUI/Accessibility dependent and are verified manually, not here.
final class ClipFileStorageTests: XCTestCase {
    private func makeTempFile(_ contents: String, ext: String = "txt") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sample.\(ext)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeFileClip(_ db: ClipDatabase, name: String, stored: MediaStore.StoredFile?, path: String) -> Clip {
        var clip = makeTextClip(name)
        clip.contentKind = .file
        clip.filePath = path
        clip.mediaFilename = stored?.mediaFilename
        clip.byteSize = stored?.byteSize
        return clip
    }

    func testStoreFileCopiesBytesIntoMediaStore() throws {
        let db = try makeTestDatabase(self)
        let src = try makeTempFile("hello file clip")          // 15 bytes
        let stored = try db.media.storeFile(at: src)
        XCTAssertEqual(stored.byteSize, 15)
        let copied = db.media.url(for: stored.mediaFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(try Data(contentsOf: copied), Data("hello file clip".utf8))
        // Original extension is preserved on the stored copy.
        XCTAssertEqual(copied.pathExtension, "txt")
    }

    func testSaveFileClipPersistsAllFields() throws {
        let db = try makeTestDatabase(self)
        let src = try makeTempFile("payload", ext: "pdf")
        let stored = try db.media.storeFile(at: src)
        var clip = makeFileClip(db, name: "sample.pdf", stored: stored, path: src.path)
        try db.saveCapturedFileClip(&clip, cap: 1000)

        let all = try db.allClips()
        XCTAssertEqual(all.count, 1)
        let saved = try XCTUnwrap(all.first)
        XCTAssertEqual(saved.contentKind, .file)
        XCTAssertEqual(saved.filePath, src.path)
        XCTAssertEqual(saved.mediaFilename, stored.mediaFilename)
        XCTAssertEqual(saved.byteSize, stored.byteSize)
        XCTAssertEqual(saved.kind, .file)   // visual kind maps through
    }

    func testReferenceOnlyFileClipPersistsPathWithoutBytes() throws {
        let db = try makeTestDatabase(self)
        // Over-threshold path: no stored bytes, only a reference to the original.
        var clip = makeFileClip(db, name: "huge.iso", stored: nil, path: "/Volumes/ext/huge.iso")
        clip.byteSize = 4_000_000_000
        try db.saveCapturedFileClip(&clip, cap: 1000)

        let saved = try XCTUnwrap(try db.allClips().first)
        XCTAssertEqual(saved.contentKind, .file)
        XCTAssertEqual(saved.filePath, "/Volumes/ext/huge.iso")
        XCTAssertNil(saved.mediaFilename)        // reference only, no local copy
        XCTAssertEqual(saved.byteSize, 4_000_000_000)
    }

    func testDuplicateFileClipIsDeduped() throws {
        let db = try makeTestDatabase(self)
        let src = try makeTempFile("dupe")
        let stored = try db.media.storeFile(at: src)

        var first = makeFileClip(db, name: "sample.txt", stored: stored, path: src.path)
        try db.saveCapturedFileClip(&first, cap: 1000)
        var second = makeFileClip(db, name: "sample.txt", stored: stored, path: src.path)
        try db.saveCapturedFileClip(&second, cap: 1000)

        XCTAssertEqual(try db.allClips().count, 1, "same stored file should dedupe, not duplicate")
    }
}

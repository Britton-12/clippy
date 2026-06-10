import Foundation
import XCTest
@testable import Clippy

/// Creates an isolated ClipDatabase in a fresh temp directory.
func makeTestDatabase(_ testCase: XCTestCase) throws -> ClipDatabase {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clippy-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: dir)
    }
    return try ClipDatabase(
        databaseURL: dir.appendingPathComponent("test.sqlite"),
        mediaDirectory: dir.appendingPathComponent("media", isDirectory: true)
    )
}

func makeImageClip(_ stored: MediaStore.StoredImage, createdAt: Date = Date()) -> Clip {
    Clip(
        id: nil,
        contentText: "",
        contentRTF: nil,
        contentHTML: nil,
        typeIdentifier: "public.png",
        sourceAppBundleID: "com.example.test",
        sourceAppName: "TestApp",
        createdAt: createdAt,
        contentKind: .image,
        mediaFilename: stored.mediaFilename,
        thumbFilename: stored.thumbFilename,
        pixelWidth: stored.pixelWidth,
        pixelHeight: stored.pixelHeight,
        byteSize: stored.byteSize
    )
}

func makeTextClip(_ text: String, createdAt: Date = Date()) -> Clip {
    Clip(
        id: nil,
        contentText: text,
        contentRTF: nil,
        contentHTML: nil,
        typeIdentifier: "public.utf8-plain-text",
        sourceAppBundleID: "com.example.test",
        sourceAppName: "TestApp",
        createdAt: createdAt
    )
}

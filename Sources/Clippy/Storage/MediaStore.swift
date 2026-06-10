import AppKit
import CryptoKit
import Foundation

enum MediaStoreError: Error {
    case undecodableImage
    case thumbnailFailed
}

/// Owns the on-disk directory for image clip payloads and thumbnails.
/// The database stores filenames only; the filename is the SHA-256 of the
/// PNG bytes, which makes storing the same image twice naturally idempotent.
final class MediaStore {
    struct StoredImage: Equatable {
        let mediaFilename: String
        let thumbFilename: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteSize: Int
    }

    let directory: URL
    private static let thumbnailMaxEdge: CGFloat = 400

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Writes the image and a small thumbnail; both must exist before the
    /// caller commits a database row, so a row never references missing bytes.
    func store(pngData: Data) throws -> StoredImage {
        guard let rep = NSBitmapImageRep(data: pngData) else {
            throw MediaStoreError.undecodableImage
        }
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        let mediaFilename = "\(hash).png"
        let thumbFilename = "\(hash)-thumb.jpg"
        let mediaURL = url(for: mediaFilename)
        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try pngData.write(to: mediaURL, options: .atomic)
            try Self.thumbnailJPEG(from: rep).write(to: url(for: thumbFilename), options: .atomic)
        }
        return StoredImage(
            mediaFilename: mediaFilename,
            thumbFilename: thumbFilename,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            byteSize: pngData.count
        )
    }

    func delete(filenames: [String]) {
        for filename in filenames where !filename.isEmpty {
            try? FileManager.default.removeItem(at: url(for: filename))
        }
    }

    /// Removes files no clip references (leftovers from a crash between file
    /// write and row insert).
    func sweepOrphans(referencedFilenames: Set<String>) {
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for filename in onDisk where !referencedFilenames.contains(filename) {
            try? FileManager.default.removeItem(at: url(for: filename))
        }
    }

    private static func thumbnailJPEG(from rep: NSBitmapImageRep) throws -> Data {
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        let scale = min(1, thumbnailMaxEdge / max(width, height))
        let targetSize = NSSize(width: max(1, width * scale), height: max(1, height * scale))
        let image = NSImage(size: targetSize)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: targetSize))
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let thumbRep = NSBitmapImageRep(data: tiff),
            let jpeg = thumbRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw MediaStoreError.thumbnailFailed }
        return jpeg
    }
}

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
        let thumbURL = url(for: thumbFilename)
        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try pngData.write(to: mediaURL, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: thumbURL.path) {
            try Self.thumbnailJPEG(from: rep).write(to: thumbURL, options: .atomic)
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
    /// write and row insert). Files younger than a minute are spared: they may
    /// belong to a capture whose database row is still in flight.
    func sweepOrphans(referencedFilenames: Set<String>) {
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for filename in onDisk where !referencedFilenames.contains(filename) {
            let fileURL = url(for: filename)
            if let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) < 60 {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// CGContext (not NSImage.lockFocus) so this is safe off the main thread;
    /// capture may run from background callers.
    private static func thumbnailJPEG(from rep: NSBitmapImageRep) throws -> Data {
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        guard width > 0, height > 0, let cgImage = rep.cgImage else {
            throw MediaStoreError.thumbnailFailed
        }
        let scale = min(1, thumbnailMaxEdge / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MediaStoreError.thumbnailFailed }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { throw MediaStoreError.thumbnailFailed }
        guard let jpeg = NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw MediaStoreError.thumbnailFailed }
        return jpeg
    }
}

import AppKit
import Foundation
import GRDB

// Database side of the clippy.toml archive: reading categories with their
// pinned clips for export, and idempotent upserts for import. Import is
// deliberately non-destructive: existing categories (matched by name) are
// updated in place and identical text clips are reused, so re-importing an
// edited file does not pile up duplicates.
extension ClipDatabase {

    // MARK: - Export

    /// Every category in display order, each paired with its pinned clips
    /// (newest first). The unit the TOML archive is built from.
    func clipsGroupedByCategory() throws -> [(category: Category, clips: [Clip])] {
        try dbQueue.read { db in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            var result: [(Category, [Clip])] = []
            for category in categories {
                guard let id = category.id else { continue }
                let clips = try Clip.fetchAll(
                    db,
                    sql: """
                        SELECT clips.* FROM clips
                        JOIN clip_category ON clip_category.clipID = clips.id
                        WHERE clip_category.categoryID = ?
                        ORDER BY clips.createdAt DESC, clips.id DESC
                        """,
                    arguments: [id]
                )
                result.append((category, clips))
            }
            return result
        }
    }

    // MARK: - Import

    /// Find a category by name and update its style/order, or create it. The
    /// `starter` flag only takes effect when no starter exists yet (the schema
    /// allows at most one).
    func upsertImportedCategory(
        name: String,
        colorHex: String,
        iconKind: CategoryIconKind,
        iconValue: String,
        position: Int,
        starter: Bool
    ) throws -> Int64 {
        try dbQueue.write { db in
            if var existing = try Category.filter(Column("name") == name).fetchOne(db) {
                existing.colorHex = colorHex
                existing.iconKind = iconKind
                existing.iconValue = iconValue
                existing.sortOrder = position
                try existing.update(db)
                return existing.id ?? -1
            }
            var makeStarter = false
            if starter {
                let hasStarter = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM category WHERE isStarter = 1)"
                ) ?? false
                makeStarter = !hasStarter
            }
            var category = Category(
                id: nil, name: name, colorHex: colorHex,
                iconKind: iconKind, iconValue: iconValue,
                sortOrder: position, isStarter: makeStarter, createdAt: Date()
            )
            try category.insert(db)
            return category.id ?? -1
        }
    }

    /// Reuse an identical text clip if present (so re-import does not duplicate),
    /// applying the imported title; otherwise insert a new one. No cap eviction:
    /// imported clips are about to be categorized and are not subject to the cap.
    func upsertImportedTextClip(
        text: String, title: String?, sourceApp: String?, createdAt: Date
    ) throws -> Int64 {
        try dbQueue.write { db in
            if let existing = try Clip
                .filter(Column("contentText") == text)
                .filter(Column("contentKind") == ClipContentKind.text.rawValue)
                .fetchOne(db)
            {
                let id = existing.id ?? -1
                if let title {
                    try db.execute(sql: "UPDATE clips SET userTitle = ? WHERE id = ?", arguments: [title, id])
                }
                return id
            }
            var clip = Clip(
                id: nil, contentText: text, contentRTF: nil, contentHTML: nil,
                typeIdentifier: "public.utf8-plain-text",
                sourceAppBundleID: nil, sourceAppName: sourceApp,
                createdAt: createdAt, contentKind: .text,
                mediaFilename: nil, thumbFilename: nil,
                pixelWidth: nil, pixelHeight: nil, byteSize: nil, userTitle: title
            )
            try clip.insert(db)
            return clip.id ?? -1
        }
    }

    /// Re-ingest an image clip from a file on disk (the path stored in the
    /// archive). Returns nil when the file is missing or not a readable image,
    /// so the caller can count it as skipped rather than fail the whole import.
    func upsertImportedImageClip(
        fromFileAt path: String, title: String?, sourceApp: String?, createdAt: Date
    ) throws -> Int64? {
        guard let raw = FileManager.default.contents(atPath: path) else { return nil }
        // Normalize to PNG via the imaging stack; a Clippy-exported PNG passes
        // through unchanged, other formats are converted.
        let pngData: Data
        if let image = NSImage(data: raw),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pngData = png
        } else {
            return nil
        }
        let stored = try media.store(pngData: pngData)
        return try dbQueue.write { db in
            if let existing = try Clip.filter(Column("mediaFilename") == stored.mediaFilename).fetchOne(db) {
                return existing.id
            }
            var clip = Clip(
                id: nil, contentText: "", contentRTF: nil, contentHTML: nil,
                typeIdentifier: "public.png",
                sourceAppBundleID: nil, sourceAppName: sourceApp,
                createdAt: createdAt, contentKind: .image,
                mediaFilename: stored.mediaFilename, thumbFilename: stored.thumbFilename,
                pixelWidth: stored.pixelWidth, pixelHeight: stored.pixelHeight,
                byteSize: stored.byteSize, userTitle: title
            )
            try clip.insert(db)
            return clip.id
        }
    }
}

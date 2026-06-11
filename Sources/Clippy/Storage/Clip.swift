import Foundation
import GRDB

enum ClipContentKind: String, Codable {
    case text
    case image
}

struct Clip: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var contentText: String
    var contentRTF: Data?
    var contentHTML: Data?
    var typeIdentifier: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var contentKind: ClipContentKind = .text
    var mediaFilename: String?
    var thumbFilename: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteSize: Int?
    /// User-supplied display name. When nil the source app name is shown instead.
    var userTitle: String? = nil

    static let databaseTableName = "clips"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The title shown in the card header: user's custom name when set,
    /// otherwise the source app name, otherwise a generic fallback.
    var displayTitle: String {
        userTitle ?? sourceAppName ?? "Unknown app"
    }

    /// Single-line-ish preview for list rows.
    var previewText: String {
        let trimmed = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(300))
    }

    var isRich: Bool {
        contentRTF != nil || contentHTML != nil
    }

    /// Media filenames this clip owns on disk (empty for text clips).
    var mediaFilenames: [String] {
        [mediaFilename, thumbFilename].compactMap { $0 }
    }
}

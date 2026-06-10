import Foundation
import GRDB

enum CategoryIconKind: String, Codable {
    case symbol
    case emoji
    case appLogo
}

/// A user-defined pinboard. A clip is "pinned" when it belongs to at least
/// one category (tag model: a clip can be in several at once).
struct Category: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var colorHex: String
    var iconKind: CategoryIconKind
    var iconValue: String
    var sortOrder: Int
    var isStarter: Bool
    var createdAt: Date

    static let databaseTableName = "category"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Junction row: one clip's membership in one category.
struct ClipCategory: Codable, FetchableRecord, PersistableRecord {
    var clipID: Int64
    var categoryID: Int64
    var addedAt: Date

    static let databaseTableName = "clip_category"
}

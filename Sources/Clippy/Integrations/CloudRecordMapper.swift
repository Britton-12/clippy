import CloudKit
import Foundation

enum CloudSchema {
    static let containerIdentifier = "iCloud.com.henssler.clippy"
    static let zoneName = "ClippyZone"
    static let clipType = "Clip"
    static let categoryType = "Category"
}

/// Translates Clippy's models to and from CKRecords. Pure value conversion with
/// no network, so it is unit-testable. Record names use a stable content key so
/// the same clip copied on two devices converges instead of duplicating.
struct CloudRecordMapper {
    let zoneID: CKRecordZone.ID

    init(zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: CloudSchema.zoneName, ownerName: CKCurrentUserDefaultName)) {
        self.zoneID = zoneID
    }

    // MARK: - Clips

    /// Stable cross-device identity: image clips key on their content-hash media
    /// filename; text clips key on a hash of their text.
    func recordName(for clip: Clip) -> String {
        if clip.contentKind == .image, let media = clip.mediaFilename {
            return "clip-img-\(media)"
        }
        return "clip-txt-\(stableHash(clip.contentText))"
    }

    func record(for clip: Clip) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName(for: clip), zoneID: zoneID)
        let record = CKRecord(recordType: CloudSchema.clipType, recordID: recordID)
        record["contentText"] = clip.contentText as CKRecordValue
        record["typeIdentifier"] = clip.typeIdentifier as CKRecordValue
        record["contentKind"] = clip.contentKind.rawValue as CKRecordValue
        record["createdAt"] = clip.createdAt as CKRecordValue
        if let title = clip.userTitle { record["userTitle"] = title as CKRecordValue }
        if let app = clip.sourceAppName { record["sourceAppName"] = app as CKRecordValue }
        if let bundle = clip.sourceAppBundleID { record["sourceAppBundleID"] = bundle as CKRecordValue }
        if let media = clip.mediaFilename { record["mediaFilename"] = media as CKRecordValue }
        if let thumb = clip.thumbFilename { record["thumbFilename"] = thumb as CKRecordValue }
        if let w = clip.pixelWidth { record["pixelWidth"] = w as CKRecordValue }
        if let h = clip.pixelHeight { record["pixelHeight"] = h as CKRecordValue }
        if let size = clip.byteSize { record["byteSize"] = size as CKRecordValue }
        return record
    }

    func clip(from record: CKRecord) -> Clip? {
        guard record.recordType == CloudSchema.clipType,
              let contentText = record["contentText"] as? String,
              let typeIdentifier = record["typeIdentifier"] as? String,
              let createdAt = record["createdAt"] as? Date else { return nil }
        let kind = ClipContentKind(rawValue: record["contentKind"] as? String ?? "text") ?? .text
        return Clip(
            id: nil,
            contentText: contentText,
            contentRTF: nil,
            contentHTML: nil,
            typeIdentifier: typeIdentifier,
            sourceAppBundleID: record["sourceAppBundleID"] as? String,
            sourceAppName: record["sourceAppName"] as? String,
            createdAt: createdAt,
            contentKind: kind,
            mediaFilename: record["mediaFilename"] as? String,
            thumbFilename: record["thumbFilename"] as? String,
            pixelWidth: (record["pixelWidth"] as? Int),
            pixelHeight: (record["pixelHeight"] as? Int),
            byteSize: (record["byteSize"] as? Int),
            userTitle: record["userTitle"] as? String
        )
    }

    // MARK: - Categories

    func recordName(for category: Category) -> String {
        "category-\(stableHash(category.name))"
    }

    func record(for category: Category) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName(for: category), zoneID: zoneID)
        let record = CKRecord(recordType: CloudSchema.categoryType, recordID: recordID)
        record["name"] = category.name as CKRecordValue
        record["colorHex"] = category.colorHex as CKRecordValue
        record["iconKind"] = category.iconKind.rawValue as CKRecordValue
        record["iconValue"] = category.iconValue as CKRecordValue
        record["sortOrder"] = category.sortOrder as CKRecordValue
        record["isStarter"] = (category.isStarter ? 1 : 0) as CKRecordValue
        record["createdAt"] = category.createdAt as CKRecordValue
        return record
    }

    func category(from record: CKRecord) -> Category? {
        guard record.recordType == CloudSchema.categoryType,
              let name = record["name"] as? String,
              let colorHex = record["colorHex"] as? String,
              let iconValue = record["iconValue"] as? String,
              let createdAt = record["createdAt"] as? Date else { return nil }
        let iconKind = CategoryIconKind(rawValue: record["iconKind"] as? String ?? "symbol") ?? .symbol
        return Category(
            id: nil,
            name: name,
            colorHex: colorHex,
            iconKind: iconKind,
            iconValue: iconValue,
            sortOrder: (record["sortOrder"] as? Int) ?? 0,
            isStarter: (record["isStarter"] as? Int) == 1,
            createdAt: createdAt
        )
    }

    /// A stable, platform-independent hash for record names (FNV-1a). Avoids
    /// Swift's per-process-randomized Hashable.
    private func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

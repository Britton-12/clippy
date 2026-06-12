import CloudKit
import Foundation

/// Mirrors clips and categories to the user's private CloudKit database so they
/// appear on the user's other Macs. Fully guarded: it does nothing unless the
/// setting is on AND an iCloud account is available, and every CloudKit call is
/// wrapped so a missing entitlement or sign-out degrades to a status message
/// rather than a crash.
///
/// Requires, in a signed build: the iCloud capability with CloudKit and the
/// container `iCloud.com.henssler.clippy` (see CloudSchema). Not exercised by the
/// unit tests, which cover the record mapping; live sync needs an entitled build.
@MainActor
final class CloudSyncEngine: ObservableObject {
    static let shared = CloudSyncEngine()

    @Published private(set) var status = "Idle"
    @Published private(set) var syncing = false

    private let mapper = CloudRecordMapper()
    private var container: CKContainer { CKContainer(identifier: CloudSchema.containerIdentifier) }
    private var database: CKDatabase { container.privateCloudDatabase }

    /// Called at launch and when the toggle flips. Safe no-op unless enabled.
    func startIfEnabled() {
        guard AppSettings.shared.iCloudSyncEnabled else { return }
        Task { await sync() }
    }

    func sync() async {
        guard AppSettings.shared.iCloudSyncEnabled else { return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            let account = try await container.accountStatus()
            guard account == .available else {
                status = "iCloud account not available."
                return
            }
            try await ensureZone()
            let pushed = try await pushLocal()
            let pulled = try await pullRemote()
            status = "Synced. Pushed \(pushed), pulled \(pulled)."
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Steps

    private func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: mapper.zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
    }

    private func pushLocal() async throws -> Int {
        let db = ClipDatabase.shared
        var records = try db.allClips().map { mapper.record(for: $0) }
        records += try db.categories().map { mapper.record(for: $0) }
        for chunk in records.chunked(into: 200) {
            _ = try await database.modifyRecords(saving: chunk, deleting: [],
                                                 savePolicy: .changedKeys, atomically: false)
        }
        return records.count
    }

    private func pullRemote() async throws -> Int {
        var applied = 0
        applied += try await pullClips()
        applied += try await pullCategories()
        return applied
    }

    private func pullClips() async throws -> Int {
        let query = CKQuery(recordType: CloudSchema.clipType, predicate: NSPredicate(value: true))
        let (matches, _) = try await database.records(matching: query, inZoneWith: mapper.zoneID)
        var applied = 0
        let db = ClipDatabase.shared
        for (_, result) in matches {
            guard case .success(let record) = result, let clip = mapper.clip(from: record) else { continue }
            // Only text clips can be reconstituted from CloudKit metadata; image
            // clips reference a local media file that this version does not ship
            // as a CKAsset, so they are skipped on pull.
            guard clip.contentKind == .text else { continue }
            _ = try? db.upsertImportedTextClip(text: clip.contentText, title: clip.userTitle,
                                               sourceApp: clip.sourceAppName, createdAt: clip.createdAt)
            applied += 1
        }
        return applied
    }

    private func pullCategories() async throws -> Int {
        let query = CKQuery(recordType: CloudSchema.categoryType, predicate: NSPredicate(value: true))
        let (matches, _) = try await database.records(matching: query, inZoneWith: mapper.zoneID)
        var applied = 0
        let db = ClipDatabase.shared
        let existing = (try? db.categories().map(\.name)) ?? []
        for (_, result) in matches {
            guard case .success(let record) = result, let category = mapper.category(from: record) else { continue }
            // Non-destructive: create categories that do not already exist by name.
            guard !category.isStarter, !existing.contains(category.name) else { continue }
            _ = try? db.createCategory(named: category.name, colorHex: category.colorHex,
                                       iconKind: category.iconKind, iconValue: category.iconValue)
            applied += 1
        }
        return applied
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

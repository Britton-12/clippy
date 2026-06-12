import Foundation

/// iCloud sync that actually works for a Developer-ID / Sparkle-distributed app.
///
/// CloudKit is intentionally NOT used: it requires App Store or development
/// provisioning that a directly-distributed (Developer ID) app cannot have, and
/// touching it without the entitlement crashes the process. Instead this writes
/// Clippy's archive into the user's iCloud Drive folder as a regular file. A
/// non-sandboxed app can read and write there with no entitlement, and iCloud
/// uploads/downloads it across the user's Macs.
///
/// Merge is non-destructive: it reuses ClippyArchive's TOML import (add/update,
/// never clear), so two devices converge instead of clobbering each other.
@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()

    @Published private(set) var status = "Idle"
    @Published private(set) var syncing = false

    private let syncFileName = "clippy-sync.toml"

    /// Tests (and the launch self-test) inject a local folder here instead of the
    /// real iCloud Drive path.
    private let rootOverride: URL?

    init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
    }

    /// The local mirror of the user's iCloud Drive ("iCloud Drive > Clippy").
    /// nil when the user does not have iCloud Drive enabled.
    static var systemICloudDriveRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    private func driveRoot() -> URL? { rootOverride ?? Self.systemICloudDriveRoot }

    var isAvailable: Bool { driveRoot() != nil }

    private func syncFileURL() -> URL? {
        guard let root = driveRoot() else { return nil }
        let dir = root.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(syncFileName)
    }

    /// Called at launch and when the toggle flips. Safe no-op unless enabled.
    func startIfEnabled() {
        guard AppSettings.shared.iCloudSyncEnabled else { return }
        Task { await sync() }
    }

    func sync(force: Bool = false) async {
        guard force || AppSettings.shared.iCloudSyncEnabled else { return }
        guard !syncing else { return }
        guard let url = syncFileURL() else {
            status = "iCloud Drive is not enabled on this Mac."
            return
        }
        syncing = true
        defer { syncing = false }

        do {
            // Pull: merge any archive another device wrote (non-destructive).
            try await pullIfPresent(url)
            // Push: write the merged local state back for the other devices.
            let toml = try ClippyArchive.exportTOML(from: ClipDatabase.shared)
            try toml.write(to: url, atomically: true, encoding: .utf8)
            status = "Synced via iCloud Drive."
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func pullIfPresent(_ url: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // iCloud keeps a not-yet-downloaded item as a hidden ".name.icloud"
            // placeholder. Only wait when one actually exists; otherwise there is
            // nothing remote to pull and we return immediately (no first-sync stall).
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            guard fm.fileExists(atPath: placeholder.path) else { return }
            try? fm.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<10 where !fm.fileExists(atPath: url.path) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard fm.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try ClippyArchive.importTOML(text, into: ClipDatabase.shared)
    }
}

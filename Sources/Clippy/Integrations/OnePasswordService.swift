import Foundation

/// One 1Password item as surfaced in the sidebar (no secret value until revealed).
struct OPItem: Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let updatedAt: String?
}

enum OnePasswordError: LocalizedError {
    case notInstalled
    case notSignedIn(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The 1Password CLI (op) was not found. Install 1Password 8 and enable the command-line tool."
        case .notSignedIn(let detail):
            return "Not signed in to 1Password. \(detail)"
        case .command(let detail):
            return detail
        }
    }
}

/// Wraps the 1Password `op` CLI. Clippy reads items from one vault (default
/// "Clippy") and can create new secrets there; revealing a value invokes `op`,
/// which prompts the user via the 1Password app for biometric/app unlock. No
/// secret values are persisted by Clippy.
struct OnePasswordService {
    let vault: String

    init(vault: String) {
        self.vault = vault.isEmpty ? "Clippy" : vault
    }

    /// Resolve the op executable. GUI apps get a minimal PATH, so the common
    /// install locations are checked before falling back to env-resolved PATH.
    static func executablePath() -> String? {
        let candidates = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executablePath() != nil }

    private func op(_ args: [String]) async throws -> String {
        guard let path = Self.executablePath() else { throw OnePasswordError.notInstalled }
        let result = await Subprocess.run(path, args)
        guard result.succeeded else {
            let lower = result.stderr.lowercased()
            if lower.contains("sign in") || lower.contains("not currently signed in") || lower.contains("authorization") {
                throw OnePasswordError.notSignedIn(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw OnePasswordError.command(result.stderr.isEmpty
                ? "op exited with code \(result.exitCode)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    // MARK: - Operations

    func listItems() async throws -> [OPItem] {
        let json = try await op(["item", "list", "--vault", vault, "--format", "json"])
        return Self.parseItems(Data(json.utf8))
    }

    /// Reveal the primary concealed value of an item (prompts via the 1Password app).
    func revealValue(itemID: String) async throws -> String {
        let json = try await op(["item", "get", itemID, "--vault", vault, "--format", "json"])
        guard let value = Self.parsePrimaryValue(Data(json.utf8)) else {
            throw OnePasswordError.command("That item has no readable secret field.")
        }
        return value
    }

    /// Create a new Password item in the Clippy vault.
    func createSecret(title: String, value: String) async throws {
        _ = try await op(["item", "create", "--category", "Password",
                          "--title", title, "--vault", vault, "password=\(value)"])
    }

    // MARK: - Parsing (pure, tested)

    static func parseItems(_ data: Data) -> [OPItem] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { obj in
            guard let id = obj["id"] as? String, let title = obj["title"] as? String else { return nil }
            let category = (obj["category"] as? String) ?? "ITEM"
            let updated = obj["updated_at"] as? String ?? obj["last_edited_at"] as? String
            return OPItem(id: id, title: title, category: category, updatedAt: updated)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The credential value: prefer a CONCEALED field labelled/ided "password",
    /// then any non-empty concealed field, then any non-empty field value.
    static func parsePrimaryValue(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = obj["fields"] as? [[String: Any]] else { return nil }

        func value(_ f: [String: Any]) -> String? {
            (f["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func isConcealed(_ f: [String: Any]) -> Bool {
            (f["type"] as? String)?.uppercased() == "CONCEALED"
        }
        func isPassword(_ f: [String: Any]) -> Bool {
            let id = (f["id"] as? String)?.lowercased()
            let label = (f["label"] as? String)?.lowercased()
            return id == "password" || label == "password"
        }

        if let f = fields.first(where: { isConcealed($0) && isPassword($0) }), let v = value(f) { return v }
        if let f = fields.first(where: { isConcealed($0) && value($0) != nil }), let v = value(f) { return v }
        if let f = fields.first(where: { value($0) != nil }), let v = value(f) { return v }
        return nil
    }
}

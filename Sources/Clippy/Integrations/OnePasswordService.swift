import Foundation

/// One 1Password item as surfaced in the sidebar (no secret value until revealed).
struct OPItem: Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let updatedAt: String?
}

/// The type of a single field inside a 1Password item.
enum OPFieldType: String, Equatable {
    case concealed = "CONCEALED"
    case string    = "STRING"
    case otp       = "OTP"
    case url       = "URL"
    case email     = "EMAIL"
    case phone     = "PHONE"
    case date      = "DATE"
    case monthYear = "MONTH_YEAR"
    case menu      = "MENU"
    case reference = "REFERENCE"
    case unknown

    init(raw: String) {
        self = OPFieldType(rawValue: raw.uppercased()) ?? .unknown
    }

    var isConcealed: Bool { self == .concealed }
    var isOTP: Bool       { self == .otp }
}

/// A section header inside an item (the "General", "Section A" groupings).
struct OPSection: Equatable {
    let id: String
    let label: String
}

/// One field in a 1Password item. Values are never logged or persisted.
struct OPField: Identifiable, Equatable {
    let id: String
    let label: String
    let type: OPFieldType
    /// Nil for CONCEALED and OTP until explicitly fetched.
    let value: String?
    let section: OPSection?
    /// The purpose hint from op (e.g. "USERNAME", "PASSWORD", "NOTES").
    let purpose: String?
}

/// Full detail for one 1Password item, returned by `fetchItemDetail`.
struct OPItemDetail: Equatable {
    let id: String
    let title: String
    let category: String
    /// Fields in the order op returns them, preserving section grouping.
    let fields: [OPField]

    /// Field IDs grouped by section id, preserving op's order. nil key = no section.
    var sectionedFields: [(section: OPSection?, fields: [OPField])] {
        var buckets: [(OPSection?, [OPField])] = []
        var keyOrder: [String?] = []  // nil = unsectioned

        for field in fields {
            let key = field.section?.id
            if !keyOrder.contains(where: { $0 == key }) {
                keyOrder.append(key)
                buckets.append((field.section, [field]))
            } else if let idx = buckets.firstIndex(where: { $0.0?.id == key }) {
                buckets[idx].1.append(field)
            }
        }
        return buckets
    }
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

    /// Resolve the op executable. GUI apps receive a stripped PATH, so common
    /// install locations are probed first, then PATH is consulted via /usr/bin/env.
    static func executablePath() -> String? {
        let hardcoded = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]
        if let found = hardcoded.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Fall back to PATH lookup: /usr/bin/env itself is always at a fixed path.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/env") {
            return "/usr/bin/env"
        }
        return nil
    }

    /// Arguments to prepend when the resolved path is /usr/bin/env (PATH lookup).
    private static func opArgs(base: [String]) -> (String, [String]) {
        let path = executablePath() ?? "/opt/homebrew/bin/op"
        if path == "/usr/bin/env" {
            return (path, ["op"] + base)
        }
        return (path, base)
    }

    // Cached for the process lifetime: the settings UI reads this several times
    // per render, and the CLI is not installed or removed mid-session in practice.
    // Caching turns a dozen filesystem stats per render into one lookup.
    private static let installedCache: Bool = executablePath() != nil
    static var isInstalled: Bool { installedCache }

    private func op(_ args: [String]) async throws -> String {
        guard let _ = Self.executablePath() else { throw OnePasswordError.notInstalled }
        let (exe, fullArgs) = Self.opArgs(base: args)
        let result = await Subprocess.run(exe, fullArgs)
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

    /// Fetch full item detail including all fields. Prompts via the 1Password app.
    func fetchItemDetail(itemID: String) async throws -> OPItemDetail {
        let json = try await op(["item", "get", itemID, "--vault", vault, "--format", "json"])
        guard let detail = Self.parseItemDetail(Data(json.utf8)) else {
            throw OnePasswordError.command("Could not read item fields.")
        }
        return detail
    }

    /// Fetch the current TOTP code for a field on demand (never cached).
    /// Uses `op item get <id> --otp` which returns only the raw TOTP token.
    func fetchTOTP(itemID: String) async throws -> String {
        let raw = try await op(["item", "get", itemID, "--otp"])
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw OnePasswordError.command("No TOTP code returned.")
        }
        return code
    }

    /// Reveal the primary concealed value of an item (prompts via the 1Password app).
    /// Kept for backward compatibility with the create-flow copy action.
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

    /// Parse the full JSON object returned by `op item get --format json` into
    /// an OPItemDetail. Preserves field and section order as returned by op.
    /// Field values for CONCEALED and OTP types are retained here because the
    /// caller already authenticated via the 1Password app; the caller is
    /// responsible for never logging or persisting these values.
    static func parseItemDetail(_ data: Data) -> OPItemDetail? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let title = obj["title"] as? String else { return nil }

        let category = (obj["category"] as? String) ?? "ITEM"

        // Build a section lookup keyed by section id.
        var sectionByID: [String: OPSection] = [:]
        if let secs = obj["sections"] as? [[String: Any]] {
            for s in secs {
                guard let sid = s["id"] as? String else { continue }
                let label = (s["label"] as? String) ?? sid
                sectionByID[sid] = OPSection(id: sid, label: label)
            }
        }

        let rawFields = (obj["fields"] as? [[String: Any]]) ?? []
        let fields: [OPField] = rawFields.compactMap { f in
            guard let fid = f["id"] as? String else { return nil }
            let label   = (f["label"] as? String) ?? fid
            let typeRaw = (f["type"] as? String) ?? "STRING"
            let fieldType = OPFieldType(raw: typeRaw)
            let value   = (f["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let purpose = f["purpose"] as? String

            // Section reference is a nested object: {"id": "...", "label": "..."}
            var section: OPSection?
            if let sRef = f["section"] as? [String: Any], let sID = sRef["id"] as? String {
                // Prefer the top-level sections array for canonical label; fall back
                // to the inline label on the field's section ref.
                if let known = sectionByID[sID] {
                    section = known
                } else {
                    let sLabel = (sRef["label"] as? String) ?? sID
                    section = OPSection(id: sID, label: sLabel)
                }
            }

            return OPField(id: fid, label: label, type: fieldType,
                           value: value, section: section, purpose: purpose)
        }

        return OPItemDetail(id: id, title: title, category: category, fields: fields)
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

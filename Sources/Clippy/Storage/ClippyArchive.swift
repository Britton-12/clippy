import Foundation
import TOMLKit

// The clippy.toml archive: a human-readable, structured export of every
// category (name, color, icon, position) together with the clips pinned into
// it. Designed to be hand-edited in bulk and re-imported.
//
// Schema (schema_version = 1):
//
//   schema_version = 1
//   exported_at    = "2026-06-11T04:00:00Z"   # ISO-8601, informational
//
//   [[category]]
//   name      = "Pinned"
//   color     = "#FF9500"     # hex RRGGBB
//   icon_kind = "symbol"      # "symbol" (SF Symbol) | "emoji" | "app" (bundle id)
//   icon      = "pin.fill"    # symbol name, emoji character, or app bundle id
//   position  = 0             # display order; lower sits higher in the list
//   starter   = true          # the built-in quick-pin category; at most one
//
//     [[category.clip]]
//     kind       = "text"            # "text" | "image"
//     title      = "Build"           # optional; omit to show the source app name
//     text       = "swift build"     # required for text clips
//     source_app = "Terminal"        # optional, informational
//     created_at = "2026-06-11T03:00:00Z"  # optional
//
//     [[category.clip]]
//     kind       = "image"
//     image_path = "/path/to/media/ab12.png"  # re-ingested on import if present
//
// Import is idempotent: categories are matched by name and updated in place,
// and identical text clips are reused rather than duplicated.

// MARK: - Codable model

struct ClippyArchiveDocument: Codable, Equatable {
    var schemaVersion: Int
    var exportedAt: String
    var category: [ArchivedCategory]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case category
    }
}

struct ArchivedCategory: Codable, Equatable {
    var name: String
    var color: String
    var iconKind: String
    var icon: String
    var position: Int
    var starter: Bool
    /// Optional: a category with no pinned clips omits the `[[category.clip]]`
    /// tables entirely, so the key is absent rather than an empty array.
    var clip: [ArchivedClip]?

    enum CodingKeys: String, CodingKey {
        case name, color, icon, position, starter, clip
        case iconKind = "icon_kind"
    }
}

struct ArchivedClip: Codable, Equatable {
    var kind: String
    var title: String?
    var text: String?
    var imagePath: String?
    var sourceApp: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, text
        case imagePath = "image_path"
        case sourceApp = "source_app"
        case createdAt = "created_at"
    }
}

/// What an import did, for a confirmation message.
struct ImportSummary: Equatable {
    var categories = 0
    var clips = 0
    var skippedImages = 0
}

// MARK: - icon kind <-> TOML

extension CategoryIconKind {
    /// "app" reads better than "appLogo" in a hand-edited file.
    var tomlValue: String { self == .appLogo ? "app" : rawValue }

    static func fromTOML(_ value: String) -> CategoryIconKind {
        switch value.lowercased() {
        case "app", "applogo": return .appLogo
        case "emoji": return .emoji
        default: return .symbol
        }
    }
}

// MARK: - Encode / decode + DB bridge

enum ClippyArchive {
    private static let header = """
        # Clippy archive - categories and their pinned clips.
        # Edit names, colors, icons, order, or clip text and re-import.
        # Re-importing is idempotent: categories are matched by name and updated
        # in place; identical text clips are reused, not duplicated.

        """

    private static var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    // MARK: Export

    /// Build the TOML text for the whole archive from the database. Hand-written
    /// (rather than encoded) so the field order, alignment, and nesting stay in
    /// the logical, human-readable shape documented above. Parsing on import
    /// goes through a real TOML parser, so any valid hand edit round-trips.
    static func exportTOML(from database: ClipDatabase, now: Date = Date()) throws -> String {
        let iso = isoFormatter
        let groups = try database.clipsGroupedByCategory()

        var out = header
        out += pair("schema_version", "1", width: 15)
        out += pair("exported_at", quote(iso.string(from: now)), width: 15)

        for group in groups {
            let category = group.category
            out += "\n[[category]]\n"
            out += pair("name", quote(category.name), width: 10)
            out += pair("color", quote(category.colorHex), width: 10)
            out += pair("icon_kind", quote(category.iconKind.tomlValue), width: 10)
            out += pair("icon", quote(category.iconValue), width: 10)
            out += pair("position", String(category.sortOrder), width: 10)
            out += pair("starter", category.isStarter ? "true" : "false", width: 10)

            for clip in group.clips {
                out += "\n  [[category.clip]]\n"
                out += clipPair("kind", quote(clip.contentKind.rawValue))
                if let title = clip.userTitle {
                    out += clipPair("title", quote(title))
                }
                if clip.contentKind == .text {
                    out += clipPair("text", quote(clip.contentText))
                } else if let media = clip.mediaFilename {
                    out += clipPair("image_path", quote(database.media.url(for: media).path))
                }
                if let app = clip.sourceAppName {
                    out += clipPair("source_app", quote(app))
                }
                out += clipPair("created_at", quote(iso.string(from: clip.createdAt)))
            }
        }
        return out
    }

    // MARK: Hand-written TOML helpers

    /// `key  = value` with the key padded to `width` for column alignment.
    private static func pair(_ key: String, _ value: String, width: Int) -> String {
        let padding = String(repeating: " ", count: max(1, width - key.count))
        return "\(key)\(padding)= \(value)\n"
    }

    /// A clip field: two-space indented under its `[[category.clip]]`, keys
    /// padded to the widest clip key ("created_at"/"source_app"/"image_path").
    private static func clipPair(_ key: String, _ value: String) -> String {
        "  " + pair(key, value, width: 11)
    }

    /// TOML string literal. Uses a multi-line basic string for values that
    /// contain newlines (clip text often does) and escapes the rest.
    private static func quote(_ string: String) -> String {
        if string.contains("\n") {
            var body = string.replacingOccurrences(of: "\\", with: "\\\\")
            body = body.replacingOccurrences(of: "\"\"\"", with: "\"\"\\\"")
            // The newline right after the opening delimiter is trimmed by TOML,
            // so the content starts cleanly on its own line.
            return "\"\"\"\n\(body)\"\"\""
        }
        var body = string.replacingOccurrences(of: "\\", with: "\\\\")
        body = body.replacingOccurrences(of: "\"", with: "\\\"")
        body = body.replacingOccurrences(of: "\t", with: "\\t")
        body = body.replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(body)\""
    }

    // MARK: Import

    /// Parse TOML text and apply it to the database. Returns a summary.
    @discardableResult
    static func importTOML(_ text: String, into database: ClipDatabase) throws -> ImportSummary {
        let document = try TOMLDecoder().decode(ClippyArchiveDocument.self, from: text)
        let iso = isoFormatter
        var summary = ImportSummary()

        for category in document.category {
            let categoryID = try database.upsertImportedCategory(
                name: category.name,
                colorHex: category.color,
                iconKind: CategoryIconKind.fromTOML(category.iconKind),
                iconValue: category.icon,
                position: category.position,
                starter: category.starter
            )
            summary.categories += 1

            for clip in (category.clip ?? []) {
                let created = clip.createdAt.flatMap { iso.date(from: $0) } ?? Date()
                if clip.kind == "image" {
                    guard let path = clip.imagePath,
                          let clipID = try database.upsertImportedImageClip(
                              fromFileAt: path, title: clip.title,
                              sourceApp: clip.sourceApp, createdAt: created
                          )
                    else { summary.skippedImages += 1; continue }
                    try database.setClip(clipID, inCategory: categoryID, true)
                    summary.clips += 1
                } else {
                    let value = clip.text ?? ""
                    guard !value.isEmpty else { continue }
                    let clipID = try database.upsertImportedTextClip(
                        text: value, title: clip.title,
                        sourceApp: clip.sourceApp, createdAt: created
                    )
                    try database.setClip(clipID, inCategory: categoryID, true)
                    summary.clips += 1
                }
            }
        }
        return summary
    }
}

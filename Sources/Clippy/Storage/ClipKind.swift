import SwiftUI

/// Lightweight content classification for badges, per-kind tinting, and the
/// color swatch on copied color values. Detection is plain string checks,
/// no regex, so it is cheap enough to run during list rendering.
enum ClipKind: Equatable {
    case link
    case email
    case colorValue(Color)
    case filePath
    case image
    case text

    static func detect(_ rawText: String) -> ClipKind {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048 else { return .text }

        let isSingleToken = !text.contains(where: \.isWhitespace)

        if isSingleToken, let color = Self.parseHexColor(text) {
            return .colorValue(color)
        }
        if isSingleToken,
           text.lowercased().hasPrefix("http://")
            || text.lowercased().hasPrefix("https://")
            || text.lowercased().hasPrefix("www.")
        {
            return .link
        }
        if isSingleToken, text.contains("@"), !text.hasPrefix("@"),
           let atIndex = text.firstIndex(of: "@"),
           text[text.index(after: atIndex)...].contains(".")
        {
            return .email
        }
        if isSingleToken, text.hasPrefix("/") || text.hasPrefix("~/"),
           text.dropFirst().contains("/")
        {
            return .filePath
        }
        return .text
    }

    var iconName: String {
        switch self {
        case .link: return "globe"
        case .email: return "envelope"
        case .colorValue: return "paintpalette"
        case .filePath: return "folder"
        case .image: return "photo"
        case .text: return "text.alignleft"
        }
    }

    var label: String {
        switch self {
        case .link: return "Link"
        case .email: return "Email"
        case .colorValue: return "Color"
        case .filePath: return "File path"
        case .image: return "Image"
        case .text: return "Text"
        }
    }

    var tint: Color {
        switch self {
        case .link: return Color(nsColor: .systemBlue)
        case .email: return Color(nsColor: .systemTeal)
        case .colorValue(let color): return color
        case .filePath: return Color(nsColor: .systemBrown)
        case .image: return Color(nsColor: .systemPurple)
        case .text: return Color(nsColor: .systemGray)
        }
    }

    // MARK: - Color parsing

    /// #RGB, #RRGGBB, or #RRGGBBAA. Delegates to the shared `parseHexColor`
    /// free function; keeps the stricter `#`-required contract for clip detection.
    static func parseHexColor(_ text: String) -> Color? {
        guard text.hasPrefix("#") else { return nil }
        return Clippy.parseHexColor(text)
    }
}

extension Clip {
    var kind: ClipKind {
        contentKind == .image ? .image : ClipKind.detect(contentText)
    }
}

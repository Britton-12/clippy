import SwiftUI

/// Lightweight content classification for badges, per-kind tinting, and the
/// color swatch on copied color values. Detection is plain string checks,
/// no regex, so it is cheap enough to run during list rendering.
enum ClipKind: Equatable {
    case link
    case email
    case colorValue(Color)
    case filePath
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
        case .text: return "text.alignleft"
        }
    }

    var label: String {
        switch self {
        case .link: return "Link"
        case .email: return "Email"
        case .colorValue: return "Color"
        case .filePath: return "File path"
        case .text: return "Text"
        }
    }

    var tint: Color {
        switch self {
        case .link: return Color(nsColor: .systemBlue)
        case .email: return Color(nsColor: .systemTeal)
        case .colorValue(let color): return color
        case .filePath: return Color(nsColor: .systemBrown)
        case .text: return Color(nsColor: .systemGray)
        }
    }

    // MARK: - Color parsing

    /// #RGB, #RRGGBB, or #RRGGBBAA.
    private static func parseHexColor(_ text: String) -> Color? {
        guard text.hasPrefix("#") else { return nil }
        let hex = String(text.dropFirst())
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }

        let expanded: String
        if hex.count == 3 {
            expanded = hex.map { "\($0)\($0)" }.joined()
        } else {
            expanded = hex
        }

        var value: UInt64 = 0
        guard Scanner(string: expanded).scanHexInt64(&value) else { return nil }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        if expanded.count == 8 {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension Clip {
    var kind: ClipKind {
        ClipKind.detect(contentText)
    }
}

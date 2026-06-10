import AppKit
import SwiftUI

// The theming vocabulary: appearance, accent, surface material, and how
// cards get their color. All stored in AppSettings; views read these enums.

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means inherit the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AccentTheme: String, CaseIterable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .system: return Color(nsColor: .controlAccentColor)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .teal: return Color(nsColor: .systemTeal)
        case .graphite: return Color(nsColor: .systemGray)
        }
    }
}

enum PanelMaterialStyle: String, CaseIterable, Identifiable {
    case ultraThin
    case thin
    case regular
    case thick
    case opaque

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraThin: return "Glass (ultra thin)"
        case .thin: return "Glass (thin)"
        case .regular: return "Frosted"
        case .thick: return "Frosted (thick)"
        case .opaque: return "Solid"
        }
    }

    /// nil means use a solid window background instead of a material.
    var material: Material? {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .opaque: return nil
        }
    }
}

enum CardColorMode: String, CaseIterable, Identifiable {
    case byApp
    case byKind
    case accent
    case neutral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .byApp: return "By source app"
        case .byKind: return "By content type"
        case .accent: return "Accent color"
        case .neutral: return "Neutral"
        }
    }
}

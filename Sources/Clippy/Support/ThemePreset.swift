import AppKit
import SwiftUI

// Real, named themes. Each preset is a full set of surface and text colors
// (a "token table") rather than a couple of sliders, so switching themes
// restyles the whole app coherently. Custom mode exposes every token to a
// color well + hex field. All resolution funnels through Theme.tokens().

// MARK: - Token table

/// Every surface and text color the panel and settings windows draw from.
/// Views never reach for NSColor.windowBackgroundColor or .secondary directly;
/// they read these so a theme switch repaints everything at once.
struct ThemeTokens {
    var panel: Color            // outermost window background
    var scrollBackground: Color // area behind the scrolling clip cards
    var cardSurface: Color      // a card's inner face
    var cardBorder: Color       // card outline / separators
    var headerBar: Color        // search bar row
    var footerBar: Color        // shortcut hint row
    var sidebar: Color          // category side pane background
    var scrollbar: Color        // scroll indicator tint
    var textPrimary: Color      // titles, body copy
    var textSecondary: Color    // dates, badges, captions
    var accent: Color           // selection, links, active state
    var success: Color          // positive/confirmation state (e.g. copied)
    var danger: Color           // destructive/error state (e.g. delete)
    var isDark: Bool            // drives scrollbar knob style and NSAppearance
}

// MARK: - Named presets

/// The theme catalog. `.system` follows macOS dynamically; `.custom` reads the
/// user's per-surface colors from AppSettings; the rest are fixed palettes
/// matching their well-known namesakes.
enum ThemePreset: String, CaseIterable, Identifiable {
    case system
    case cleanLight
    case githubDark
    case dracula
    case materialDarkPlus
    case nord
    case oneDark
    case solarizedDark
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .cleanLight: return "Clean Light"
        case .githubDark: return "GitHub Dark"
        case .dracula: return "Dracula"
        case .materialDarkPlus: return "Material Dark+"
        case .nord: return "Nord"
        case .oneDark: return "One Dark"
        case .solarizedDark: return "Solarized Dark"
        case .custom: return "Custom"
        }
    }

    /// Presets shown in the picker, in display order. `.system` and `.custom`
    /// bracket the fixed palettes.
    static var selectable: [ThemePreset] {
        [.system, .cleanLight, .githubDark, .dracula, .materialDarkPlus, .nord, .oneDark, .solarizedDark, .custom]
    }

    /// Fixed token table for the palette presets. nil for `.system` and
    /// `.custom`, which are resolved dynamically in Theme.tokens().
    var fixedTokens: ThemeTokens? {
        switch self {
        case .cleanLight:
            return ThemeTokens(
                panel: hex("#FFFFFF"), scrollBackground: hex("#F6F8FA"),
                cardSurface: hex("#FFFFFF"), cardBorder: hex("#D0D7DE"),
                headerBar: hex("#FFFFFF"), footerBar: hex("#F6F8FA"),
                sidebar: hex("#F6F8FA"), scrollbar: hex("#AfB8C1"),
                textPrimary: hex("#1F2328"), textSecondary: hex("#656D76"),
                accent: hex("#0969DA"),
                success: Color(nsColor: .systemGreen), danger: Color(nsColor: .systemRed),
                isDark: false
            )
        case .githubDark:
            return ThemeTokens(
                panel: hex("#0D1117"), scrollBackground: hex("#0D1117"),
                cardSurface: hex("#161B22"), cardBorder: hex("#30363D"),
                headerBar: hex("#161B22"), footerBar: hex("#161B22"),
                sidebar: hex("#0D1117"), scrollbar: hex("#484F58"),
                textPrimary: hex("#E6EDF3"), textSecondary: hex("#8B949E"),
                accent: hex("#2F81F7"),
                success: hex("#3FB950"), danger: hex("#F85149"),
                isDark: true
            )
        case .dracula:
            return ThemeTokens(
                panel: hex("#282A36"), scrollBackground: hex("#21222C"),
                cardSurface: hex("#343746"), cardBorder: hex("#44475A"),
                headerBar: hex("#21222C"), footerBar: hex("#21222C"),
                sidebar: hex("#21222C"), scrollbar: hex("#6272A4"),
                textPrimary: hex("#F8F8F2"), textSecondary: hex("#A6ACCD"),
                accent: hex("#BD93F9"),
                success: hex("#50FA7B"), danger: hex("#FF5555"),
                isDark: true
            )
        case .materialDarkPlus:
            return ThemeTokens(
                panel: hex("#121212"), scrollBackground: hex("#121212"),
                cardSurface: hex("#1E1E1E"), cardBorder: hex("#2C2C2C"),
                headerBar: hex("#1E1E1E"), footerBar: hex("#1E1E1E"),
                sidebar: hex("#181818"), scrollbar: hex("#3A3A3A"),
                textPrimary: hex("#FFFFFF"), textSecondary: hex("#B0B0B0"),
                accent: hex("#03DAC6"),
                success: hex("#A5D6A7"), danger: hex("#EF9A9A"),
                isDark: true
            )
        case .nord:
            return ThemeTokens(
                panel: hex("#2E3440"), scrollBackground: hex("#272B35"),
                cardSurface: hex("#3B4252"), cardBorder: hex("#4C566A"),
                headerBar: hex("#272B35"), footerBar: hex("#272B35"),
                sidebar: hex("#272B35"), scrollbar: hex("#4C566A"),
                textPrimary: hex("#ECEFF4"), textSecondary: hex("#A9B3C6"),
                accent: hex("#88C0D0"),
                success: hex("#A3BE8C"), danger: hex("#BF616A"),
                isDark: true
            )
        case .oneDark:
            return ThemeTokens(
                panel: hex("#282C34"), scrollBackground: hex("#21252B"),
                cardSurface: hex("#2C313A"), cardBorder: hex("#3B4048"),
                headerBar: hex("#21252B"), footerBar: hex("#21252B"),
                sidebar: hex("#21252B"), scrollbar: hex("#4B5263"),
                // #9299A8 lifts this from 3.98:1 to 4.90:1 on the panel background,
                // meeting WCAG AA (4.5:1) without making secondary text feel heavy.
                textPrimary: hex("#ABB2BF"), textSecondary: hex("#9299A8"),
                accent: hex("#61AFEF"),
                success: hex("#98C379"), danger: hex("#E06C75"),
                isDark: true
            )
        case .solarizedDark:
            return ThemeTokens(
                panel: hex("#002B36"), scrollBackground: hex("#00252E"),
                cardSurface: hex("#073642"), cardBorder: hex("#0E4B59"),
                headerBar: hex("#00252E"), footerBar: hex("#00252E"),
                sidebar: hex("#00252E"), scrollbar: hex("#586E75"),
                textPrimary: hex("#EEE8D5"), textSecondary: hex("#93A1A1"),
                accent: hex("#268BD2"),
                success: hex("#859900"), danger: hex("#DC322F"),
                isDark: true
            )
        case .system, .custom:
            return nil
        }
    }

    private func hex(_ s: String) -> Color { Color(themeHex: s) }
}

// MARK: - Resolver

enum Theme {
    /// The active token table for the current settings. The single place views
    /// call to learn what color anything should be.
    static func tokens(_ settings: AppSettings) -> ThemeTokens {
        switch settings.themePreset {
        case .system:
            return systemTokens(settings)
        case .custom:
            return customTokens(settings)
        default:
            var t = settings.themePreset.fixedTokens ?? systemTokens(settings)
            // The accent picker still applies on top of any fixed palette so a
            // user can keep, say, GitHub Dark but recolor selection to green.
            if settings.accentTheme != .system {
                t.accent = settings.accentTheme.color
            }
            return t
        }
    }

    /// NSAppearance to stamp on the window so AppKit-drawn chrome (scrollbars,
    /// text caret, menus) matches the theme. `.system` defers to the user's
    /// appearance-mode choice; named/custom themes force light or dark from the
    /// token table so a dark theme never shows light scrollbars.
    static func nsAppearance(_ settings: AppSettings) -> NSAppearance? {
        switch settings.themePreset {
        case .system:
            return settings.appearanceMode.nsAppearance
        default:
            return NSAppearance(named: tokens(settings).isDark ? .darkAqua : .aqua)
        }
    }

    /// Default per-surface colors for Custom mode the first time it is opened:
    /// seed from Clean Light so the user edits a sane starting point.
    static var customSeed: ThemeTokens { ThemePreset.cleanLight.fixedTokens! }

    private static func customTokens(_ s: AppSettings) -> ThemeTokens {
        let seed = customSeed
        return ThemeTokens(
            panel: Color(themeHex: s.customPanelHex, fallback: seed.panel),
            scrollBackground: Color(themeHex: s.customScrollBgHex, fallback: seed.scrollBackground),
            cardSurface: Color(themeHex: s.customCardSurfaceHex, fallback: seed.cardSurface),
            cardBorder: Color(themeHex: s.customCardBorderHex, fallback: seed.cardBorder),
            headerBar: Color(themeHex: s.customHeaderHex, fallback: seed.headerBar),
            footerBar: Color(themeHex: s.customFooterHex, fallback: seed.footerBar),
            sidebar: Color(themeHex: s.customSidebarHex, fallback: seed.sidebar),
            scrollbar: Color(themeHex: s.customScrollbarHex, fallback: seed.scrollbar),
            textPrimary: Color(themeHex: s.customTextPrimaryHex, fallback: seed.textPrimary),
            textSecondary: Color(themeHex: s.customTextSecondaryHex, fallback: seed.textSecondary),
            accent: Color(themeHex: s.customAccentHex, fallback: seed.accent),
            // Semantic success/danger are not user-customizable; fall back to
            // system semantics so destructive/confirm states stay legible.
            success: Color(nsColor: .systemGreen), danger: Color(nsColor: .systemRed),
            isDark: s.customIsDark
        )
    }

    /// Tokens that track the live macOS appearance using semantic system colors,
    /// with full-contrast label colors (not the washed-out grays the old build
    /// used for body text).
    private static func systemTokens(_ s: AppSettings) -> ThemeTokens {
        let dark = effectiveIsDark(s)
        return ThemeTokens(
            panel: Color(nsColor: .windowBackgroundColor),
            scrollBackground: Color(nsColor: .underPageBackgroundColor),
            cardSurface: Color(nsColor: .controlBackgroundColor),
            cardBorder: Color(nsColor: .separatorColor),
            headerBar: Color(nsColor: .windowBackgroundColor),
            footerBar: Color(nsColor: .underPageBackgroundColor),
            sidebar: Color(nsColor: .underPageBackgroundColor),
            scrollbar: Color(nsColor: .tertiaryLabelColor),
            textPrimary: Color(nsColor: .labelColor),
            // secondaryLabelColor resolves to ~#8C8C8C in light mode (3.36:1 on white),
            // failing WCAG AA. In light mode, use a concrete gray (#6E6E6E, 5.10:1 on
            // white) that reads as secondary without being heavy. Dark mode keeps the
            // semantic color, which resolves to ~#8E8E9A and already passes at ~5.26:1.
            textSecondary: dark ? Color(nsColor: .secondaryLabelColor) : Color(themeHex: "#6E6E6E"),
            accent: s.accentColor,
            success: Color(nsColor: .systemGreen), danger: Color(nsColor: .systemRed),
            isDark: dark
        )
    }

    private static func effectiveIsDark(_ s: AppSettings) -> Bool {
        switch s.appearanceMode {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}

// MARK: - Hex bridging for Color / NSColor

/// Parse #RGB, #RRGGBB, or #RRGGBBAA into a SwiftUI Color. Returns nil on
/// any parse failure. Callers apply their own fallback so the two distinct
/// defaults (theme magenta vs category systemGray) stay separate.
func parseHexColor(_ hex: String) -> Color? {
    guard let ns = NSColor(themeHex: hex) else { return nil }
    return Color(nsColor: ns)
}

extension Color {
    /// Parse #RGB, #RRGGBB, or #RRGGBBAA. Falls back to the supplied color (or
    /// magenta, which is deliberately ugly so a bad token is obvious).
    init(themeHex hex: String, fallback: Color = Color(red: 1, green: 0, blue: 1)) {
        self = parseHexColor(hex) ?? fallback
    }

    /// "#RRGGBB" for persistence from a SwiftUI ColorPicker selection.
    var themeHexString: String { NSColor(self).themeHexString }

    /// #RGB, #RRGGBB, or #RRGGBBAA; falls back to system gray. Used for category
    /// colors, which deliberately fall back to gray rather than the theme magenta.
    init(hexString: String) {
        self = parseHexColor(hexString) ?? Color(nsColor: .systemGray)
    }
}

extension NSColor {
    convenience init?(themeHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 3:
            r = CGFloat((value >> 8) & 0xF) / 15
            g = CGFloat((value >> 4) & 0xF) / 15
            b = CGFloat(value & 0xF) / 15
            a = 1
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// "#RRGGBB" in sRGB. Used to store ColorPicker output back to settings.
    var themeHexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

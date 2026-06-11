import Foundation
import SwiftUI

enum PanelPositionMode: String, CaseIterable, Identifiable {
    case caret
    case mouse
    case lastPosition
    case screenCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .caret: return "At text cursor"
        case .mouse: return "At mouse pointer"
        case .lastPosition: return "Last position"
        case .screenCenter: return "Screen center"
        }
    }
}

/// Every user-facing knob, persisted in UserDefaults. Views bind to this
/// directly; services read it on each use so changes apply immediately.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let positionMode = "positionMode"
        static let panelWidth = "panelWidth"
        static let panelHeight = "panelHeight"
        static let rememberPanelSize = "rememberPanelSize"
        static let pollingIntervalMs = "pollingIntervalMs"
        static let maxHistoryItems = "maxHistoryItems"
        static let movePastedItemToTop = "movePastedItemToTop"
        static let pastePlainTextByDefault = "pastePlainTextByDefault"
        static let ignoredBundleIDs = "ignoredBundleIDs"
        static let lastPanelX = "lastPanelX"
        static let lastPanelY = "lastPanelY"
        static let appearanceMode = "appearanceMode"
        static let accentTheme = "accentTheme"
        static let panelMaterial = "panelMaterial"
        static let cardColorMode = "cardColorMode"
        static let showAppIcons = "showAppIcons"
        static let showSectionHeaders = "showSectionHeaders"
        static let captureImages = "captureImages"
        static let maxImageSizeMB = "maxImageSizeMB"
        static let captureSoundEnabled = "captureSoundEnabled"
        static let captureSoundName = "captureSoundName"  // legacy (classic enum rawValue)
        static let captureSoundID = "captureSoundID"
        static let captureSoundVolume = "captureSoundVolume"
        static let cardStyle = "cardStyle"
        static let cardTintStrength = "cardTintStrength"
        static let highContrastCardText = "highContrastCardText"
        static let fontFamily = "fontFamily"
        static let fontSizeBase = "fontSizeBase"
        // Theme system
        static let themePreset = "themePreset"
        static let panelOpacity = "panelOpacity"
        static let customIsDark = "customIsDark"
        static let customPanelHex = "customPanelHex"
        static let customScrollBgHex = "customScrollBgHex"
        static let customCardSurfaceHex = "customCardSurfaceHex"
        static let customCardBorderHex = "customCardBorderHex"
        static let customHeaderHex = "customHeaderHex"
        static let customFooterHex = "customFooterHex"
        static let customSidebarHex = "customSidebarHex"
        static let customScrollbarHex = "customScrollbarHex"
        static let customTextPrimaryHex = "customTextPrimaryHex"
        static let customTextSecondaryHex = "customTextSecondaryHex"
        static let customAccentHex = "customAccentHex"
    }

    private let defaults: UserDefaults

    @Published var positionMode: PanelPositionMode {
        didSet { defaults.set(positionMode.rawValue, forKey: Keys.positionMode) }
    }
    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: Keys.panelWidth) }
    }
    @Published var panelHeight: Double {
        didSet { defaults.set(panelHeight, forKey: Keys.panelHeight) }
    }
    @Published var rememberPanelSize: Bool {
        didSet { defaults.set(rememberPanelSize, forKey: Keys.rememberPanelSize) }
    }
    @Published var pollingIntervalMs: Double {
        didSet { defaults.set(pollingIntervalMs, forKey: Keys.pollingIntervalMs) }
    }
    @Published var maxHistoryItems: Int {
        didSet { defaults.set(maxHistoryItems, forKey: Keys.maxHistoryItems) }
    }
    @Published var movePastedItemToTop: Bool {
        didSet { defaults.set(movePastedItemToTop, forKey: Keys.movePastedItemToTop) }
    }
    @Published var pastePlainTextByDefault: Bool {
        didSet { defaults.set(pastePlainTextByDefault, forKey: Keys.pastePlainTextByDefault) }
    }
    @Published var ignoredBundleIDs: [String] {
        didSet { defaults.set(ignoredBundleIDs, forKey: Keys.ignoredBundleIDs) }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }
    @Published var accentTheme: AccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Keys.accentTheme) }
    }
    @Published var panelMaterial: PanelMaterialStyle {
        didSet { defaults.set(panelMaterial.rawValue, forKey: Keys.panelMaterial) }
    }
    @Published var cardColorMode: CardColorMode {
        didSet { defaults.set(cardColorMode.rawValue, forKey: Keys.cardColorMode) }
    }
    @Published var showAppIcons: Bool {
        didSet { defaults.set(showAppIcons, forKey: Keys.showAppIcons) }
    }
    @Published var showSectionHeaders: Bool {
        didSet { defaults.set(showSectionHeaders, forKey: Keys.showSectionHeaders) }
    }
    @Published var captureImages: Bool {
        didSet { defaults.set(captureImages, forKey: Keys.captureImages) }
    }
    @Published var maxImageSizeMB: Int {
        didSet { defaults.set(maxImageSizeMB, forKey: Keys.maxImageSizeMB) }
    }
    /// Whether to play a sound after each successful clip save. Defaults to
    /// false so existing users hear no change until they opt in.
    @Published var captureSoundEnabled: Bool {
        didSet { defaults.set(captureSoundEnabled, forKey: Keys.captureSoundEnabled) }
    }
    /// Stable identifier of the chosen capture sound, addressing any installed
    /// system sound (classic alert or modern UI sound). See SoundCatalog.
    @Published var captureSoundID: String {
        didSet { defaults.set(captureSoundID, forKey: Keys.captureSoundID) }
    }
    /// Volume in 0-100 integer percent, matching the slider range.
    @Published var captureSoundVolume: Int {
        didSet { defaults.set(captureSoundVolume, forKey: Keys.captureSoundVolume) }
    }

    // MARK: - New appearance knobs

    /// Card rendering style: filled (opaque face), bordered (outline only), or plain.
    @Published var cardStyle: CardStyle {
        didSet { defaults.set(cardStyle.rawValue, forKey: Keys.cardStyle) }
    }
    /// Identity-color tint strength on cards, 0-20 percent. 0 = no tint.
    @Published var cardTintStrength: Int {
        didSet { defaults.set(cardTintStrength, forKey: Keys.cardTintStrength) }
    }
    /// When true, card title and preview text use .primary instead of .secondary /
    /// subdued colors, improving contrast on both light and dark backgrounds.
    @Published var highContrastCardText: Bool {
        didSet { defaults.set(highContrastCardText, forKey: Keys.highContrastCardText) }
    }
    /// Panel UI font family. .systemDefault uses the system font.
    @Published var fontFamily: PanelFontFamily {
        didSet { defaults.set(fontFamily.rawValue, forKey: Keys.fontFamily) }
    }
    /// Base font size in points (11-16). The typography helper scales all roles
    /// from this value so the relative hierarchy is always preserved.
    @Published var fontSizeBase: Int {
        didSet { defaults.set(fontSizeBase, forKey: Keys.fontSizeBase) }
    }

    // MARK: - Theme

    /// Named theme preset. Drives the whole token table; see Theme.tokens().
    @Published var themePreset: ThemePreset {
        didSet { defaults.set(themePreset.rawValue, forKey: Keys.themePreset) }
    }
    /// Panel translucency, 0.30 (very see-through) to 1.0 (fully solid). At 1.0
    /// the panel is opaque with no blur, which is the fix for the washed-out
    /// look; below 1.0 a blur shows the desktop through the tinted background.
    @Published var panelOpacity: Double {
        didSet { defaults.set(panelOpacity, forKey: Keys.panelOpacity) }
    }
    /// Whether the custom palette is a dark theme (affects scrollbar/appearance).
    @Published var customIsDark: Bool {
        didSet { defaults.set(customIsDark, forKey: Keys.customIsDark) }
    }
    @Published var customPanelHex: String { didSet { defaults.set(customPanelHex, forKey: Keys.customPanelHex) } }
    @Published var customScrollBgHex: String { didSet { defaults.set(customScrollBgHex, forKey: Keys.customScrollBgHex) } }
    @Published var customCardSurfaceHex: String { didSet { defaults.set(customCardSurfaceHex, forKey: Keys.customCardSurfaceHex) } }
    @Published var customCardBorderHex: String { didSet { defaults.set(customCardBorderHex, forKey: Keys.customCardBorderHex) } }
    @Published var customHeaderHex: String { didSet { defaults.set(customHeaderHex, forKey: Keys.customHeaderHex) } }
    @Published var customFooterHex: String { didSet { defaults.set(customFooterHex, forKey: Keys.customFooterHex) } }
    @Published var customSidebarHex: String { didSet { defaults.set(customSidebarHex, forKey: Keys.customSidebarHex) } }
    @Published var customScrollbarHex: String { didSet { defaults.set(customScrollbarHex, forKey: Keys.customScrollbarHex) } }
    @Published var customTextPrimaryHex: String { didSet { defaults.set(customTextPrimaryHex, forKey: Keys.customTextPrimaryHex) } }
    @Published var customTextSecondaryHex: String { didSet { defaults.set(customTextSecondaryHex, forKey: Keys.customTextSecondaryHex) } }
    @Published var customAccentHex: String { didSet { defaults.set(customAccentHex, forKey: Keys.customAccentHex) } }

    /// The resolved token table for the active theme. Views read this.
    var theme: ThemeTokens { Theme.tokens(self) }

    /// Reset every custom-mode color to the Clean Light seed.
    func resetCustomColors() {
        let s = Theme.customSeed
        customPanelHex = s.panel.themeHexString
        customScrollBgHex = s.scrollBackground.themeHexString
        customCardSurfaceHex = s.cardSurface.themeHexString
        customCardBorderHex = s.cardBorder.themeHexString
        customHeaderHex = s.headerBar.themeHexString
        customFooterHex = s.footerBar.themeHexString
        customSidebarHex = s.sidebar.themeHexString
        customScrollbarHex = s.scrollbar.themeHexString
        customTextPrimaryHex = s.textPrimary.themeHexString
        customTextSecondaryHex = s.textSecondary.themeHexString
        customAccentHex = s.accent.themeHexString
        customIsDark = false
    }

    /// Seed the custom palette from whatever named theme is active, so "Custom"
    /// starts as an editable copy of the user's current look instead of a reset.
    func seedCustomFromActive() {
        let t = Theme.tokens(self)
        customPanelHex = t.panel.themeHexString
        customScrollBgHex = t.scrollBackground.themeHexString
        customCardSurfaceHex = t.cardSurface.themeHexString
        customCardBorderHex = t.cardBorder.themeHexString
        customHeaderHex = t.headerBar.themeHexString
        customFooterHex = t.footerBar.themeHexString
        customSidebarHex = t.sidebar.themeHexString
        customScrollbarHex = t.scrollbar.themeHexString
        customTextPrimaryHex = t.textPrimary.themeHexString
        customTextSecondaryHex = t.textSecondary.themeHexString
        customAccentHex = t.accent.themeHexString
        customIsDark = t.isDark
    }

    var accentColor: Color { accentTheme.color }

    /// Where the panel was last closed, for the "last position" mode.
    var lastPanelOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.lastPanelX) != nil else { return nil }
            return CGPoint(
                x: defaults.double(forKey: Keys.lastPanelX),
                y: defaults.double(forKey: Keys.lastPanelY)
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.lastPanelX)
                defaults.removeObject(forKey: Keys.lastPanelY)
                return
            }
            defaults.set(newValue.x, forKey: Keys.lastPanelX)
            defaults.set(newValue.y, forKey: Keys.lastPanelY)
        }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.positionMode: PanelPositionMode.caret.rawValue,
            Keys.panelWidth: 640.0,
            Keys.panelHeight: 480.0,
            Keys.rememberPanelSize: true,
            Keys.pollingIntervalMs: 200.0,
            Keys.maxHistoryItems: 500,
            Keys.movePastedItemToTop: false,
            Keys.pastePlainTextByDefault: false,
            Keys.ignoredBundleIDs: [String](),
            Keys.appearanceMode: AppearanceMode.system.rawValue,
            Keys.accentTheme: AccentTheme.system.rawValue,
            // Solid is the default: fully opaque, full-contrast, no glass effect.
            Keys.panelMaterial: PanelMaterialStyle.opaque.rawValue,
            Keys.cardColorMode: CardColorMode.byApp.rawValue,
            Keys.showAppIcons: true,
            Keys.showSectionHeaders: true,
            Keys.captureImages: true,
            Keys.maxImageSizeMB: 20,
            Keys.captureSoundEnabled: false,
            Keys.captureSoundID: SoundCatalog.defaultID,
            Keys.captureSoundVolume: 50,
            Keys.cardStyle: CardStyle.filled.rawValue,
            Keys.cardTintStrength: 8,
            Keys.highContrastCardText: false,
            Keys.fontFamily: PanelFontFamily.systemDefault.rawValue,
            Keys.fontSizeBase: 13,
            // Clean Light is the default look; it fixes the washed-out grey.
            Keys.themePreset: ThemePreset.cleanLight.rawValue,
            Keys.panelOpacity: 1.0,
            Keys.customIsDark: false,
            Keys.customPanelHex: "#FFFFFF",
            Keys.customScrollBgHex: "#F6F8FA",
            Keys.customCardSurfaceHex: "#FFFFFF",
            Keys.customCardBorderHex: "#D0D7DE",
            Keys.customHeaderHex: "#FFFFFF",
            Keys.customFooterHex: "#F6F8FA",
            Keys.customSidebarHex: "#F6F8FA",
            Keys.customScrollbarHex: "#AFB8C1",
            Keys.customTextPrimaryHex: "#1F2328",
            Keys.customTextSecondaryHex: "#656D76",
            Keys.customAccentHex: "#0969DA",
        ])
        positionMode = PanelPositionMode(rawValue: defaults.string(forKey: Keys.positionMode) ?? "") ?? .caret
        panelWidth = defaults.double(forKey: Keys.panelWidth)
        panelHeight = defaults.double(forKey: Keys.panelHeight)
        rememberPanelSize = defaults.bool(forKey: Keys.rememberPanelSize)
        pollingIntervalMs = defaults.double(forKey: Keys.pollingIntervalMs)
        maxHistoryItems = defaults.integer(forKey: Keys.maxHistoryItems)
        movePastedItemToTop = defaults.bool(forKey: Keys.movePastedItemToTop)
        pastePlainTextByDefault = defaults.bool(forKey: Keys.pastePlainTextByDefault)
        ignoredBundleIDs = defaults.stringArray(forKey: Keys.ignoredBundleIDs) ?? []
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        accentTheme = AccentTheme(rawValue: defaults.string(forKey: Keys.accentTheme) ?? "") ?? .system
        panelMaterial = PanelMaterialStyle(rawValue: defaults.string(forKey: Keys.panelMaterial) ?? "") ?? .regular
        cardColorMode = CardColorMode(rawValue: defaults.string(forKey: Keys.cardColorMode) ?? "") ?? .byApp
        showAppIcons = defaults.bool(forKey: Keys.showAppIcons)
        showSectionHeaders = defaults.bool(forKey: Keys.showSectionHeaders)
        captureImages = defaults.bool(forKey: Keys.captureImages)
        maxImageSizeMB = defaults.integer(forKey: Keys.maxImageSizeMB)
        captureSoundEnabled = defaults.bool(forKey: Keys.captureSoundEnabled)
        captureSoundID = Self.resolveSoundID(defaults)
        captureSoundVolume = defaults.integer(forKey: Keys.captureSoundVolume)
        cardStyle = CardStyle(rawValue: defaults.string(forKey: Keys.cardStyle) ?? "") ?? .filled
        cardTintStrength = defaults.integer(forKey: Keys.cardTintStrength)
        highContrastCardText = defaults.bool(forKey: Keys.highContrastCardText)
        fontFamily = PanelFontFamily(rawValue: defaults.string(forKey: Keys.fontFamily) ?? "") ?? .systemDefault
        fontSizeBase = {
            let stored = defaults.integer(forKey: Keys.fontSizeBase)
            // Clamp to valid range; 0 means the key was never written (integer returns 0).
            return stored >= 11 && stored <= 16 ? stored : 13
        }()
        themePreset = ThemePreset(rawValue: defaults.string(forKey: Keys.themePreset) ?? "") ?? .cleanLight
        panelOpacity = {
            let stored = defaults.double(forKey: Keys.panelOpacity)
            return stored >= 0.3 && stored <= 1.0 ? stored : 1.0
        }()
        customIsDark = defaults.bool(forKey: Keys.customIsDark)
        customPanelHex = defaults.string(forKey: Keys.customPanelHex) ?? "#FFFFFF"
        customScrollBgHex = defaults.string(forKey: Keys.customScrollBgHex) ?? "#F6F8FA"
        customCardSurfaceHex = defaults.string(forKey: Keys.customCardSurfaceHex) ?? "#FFFFFF"
        customCardBorderHex = defaults.string(forKey: Keys.customCardBorderHex) ?? "#D0D7DE"
        customHeaderHex = defaults.string(forKey: Keys.customHeaderHex) ?? "#FFFFFF"
        customFooterHex = defaults.string(forKey: Keys.customFooterHex) ?? "#F6F8FA"
        customSidebarHex = defaults.string(forKey: Keys.customSidebarHex) ?? "#F6F8FA"
        customScrollbarHex = defaults.string(forKey: Keys.customScrollbarHex) ?? "#AFB8C1"
        customTextPrimaryHex = defaults.string(forKey: Keys.customTextPrimaryHex) ?? "#1F2328"
        customTextSecondaryHex = defaults.string(forKey: Keys.customTextSecondaryHex) ?? "#656D76"
        customAccentHex = defaults.string(forKey: Keys.customAccentHex) ?? "#0969DA"
    }

    /// Resolve the stored sound id, migrating the legacy classic-enum key the
    /// previous build wrote ("captureSoundName" = "Tink", "Pop", ...).
    private static func resolveSoundID(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: Keys.captureSoundID), !id.isEmpty {
            return id
        }
        if let legacy = defaults.string(forKey: Keys.captureSoundName), !legacy.isEmpty {
            return "system:\(legacy)"
        }
        return SoundCatalog.defaultID
    }
}

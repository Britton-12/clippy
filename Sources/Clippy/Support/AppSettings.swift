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
            Keys.panelWidth: 420.0,
            Keys.panelHeight: 480.0,
            Keys.rememberPanelSize: true,
            Keys.pollingIntervalMs: 200.0,
            Keys.maxHistoryItems: 500,
            Keys.movePastedItemToTop: false,
            Keys.pastePlainTextByDefault: false,
            Keys.ignoredBundleIDs: [String](),
            Keys.appearanceMode: AppearanceMode.system.rawValue,
            Keys.accentTheme: AccentTheme.system.rawValue,
            Keys.panelMaterial: PanelMaterialStyle.regular.rawValue,
            Keys.cardColorMode: CardColorMode.byApp.rawValue,
            Keys.showAppIcons: true,
            Keys.showSectionHeaders: true,
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
    }
}

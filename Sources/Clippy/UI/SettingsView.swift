import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The settings window. A System-Settings-style sidebar (a fixed list of
/// sections with colored icon tiles) plus a detail pane, themed to match Clippy.
/// Built explicitly rather than with TabView, whose macOS 15 default collapses a
/// multi-tab window into a navigation sidebar with an overflow control.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: SettingsSection = SettingsSection(
        rawValue: ProcessInfo.processInfo.environment["CLIPPY_SETTINGS_SECTION"] ?? "") ?? .general

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 780, minHeight: 580)
        .tint(tokens.accent)
        // Track the theme's light/dark appearance and accent so the whole app,
        // not just the panel, follows the theme.
        .background(WindowAppearanceApplier(appearance: Theme.nsAppearance(settings)))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { sidebarRow($0) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 214, maxWidth: 214)
        .background(tokens.sidebar)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: StatusBarIcon.image())
                .renderingMode(.template)
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundStyle(tokens.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Clippy")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(tokens.textPrimary)
                Text("Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Clear the window's traffic-light controls (transparent titlebar).
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button { selection = section } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(section.tint.gradient)
                        .frame(width: 22, height: 22)
                    Image(systemName: section.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(tokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(tokens.accent.opacity(0.18)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10))
            Text("Clippy \(Bundle.main.shortVersion)")
                .font(.system(size: 10))
        }
        .foregroundStyle(tokens.textSecondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selection.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tokens.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralSettingsTab()
        case .appearance: AppearanceSettingsTab()
        case .capture: CaptureSettingsTab()
        case .ai: AISettingsTab()
        case .scripts: ScriptsView()
        case .integrations: IntegrationsSettingsTab()
        }
    }
}

/// The settings sections, in sidebar order, each with a System-Settings-style
/// colored icon tile.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, capture, ai, scripts, integrations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .capture: return "Capture"
        case .ai: return "AI"
        case .scripts: return "Scripts"
        case .integrations: return "Integrations"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .capture: return "doc.on.clipboard.fill"
        case .ai: return "sparkles"
        case .scripts: return "terminal.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .appearance: return Color(nsColor: .systemPink)
        case .capture: return Color(nsColor: .systemBlue)
        case .ai: return Color(nsColor: .systemPurple)
        case .scripts: return Color(nsColor: .systemGreen)
        case .integrations: return Color(nsColor: .systemOrange)
        }
    }
}

extension Bundle {
    /// CFBundleShortVersionString, or a dev fallback when running unbundled.
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

/// Pushes an NSAppearance onto the hosting window. Used so changing the theme
/// repaints the settings window (a grouped Form) in matching light/dark.
private struct WindowAppearanceApplier: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = appearance
        // The hosting window is often nil during the first layout pass, so defer
        // to the next runloop turn. Apply only when the value actually changed to
        // avoid redundant repaints, and no-op while the window is still nil.
        DispatchQueue.main.async {
            guard let window = view.window, window.appearance != target else { return }
            window.appearance = target
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private var isRunningFromBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Open panel", value: "\u{2318}\u{21E7}V")
                Text("Press this combination anywhere to open the Clippy panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pasting") {
                Toggle("Paste as plain text by default", isOn: $settings.pastePlainTextByDefault)
                Toggle("Move pasted item to top of history", isOn: $settings.movePastedItemToTop)
                Text("Shift+Return in the panel always pastes in the non-default mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Clicking a clip copies it without pasting", isOn: $settings.clickCopyOnly)
                Text("Off by default: clicking pastes into the active app. Turn on to only copy to the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Keystroke typing speed", selection: $settings.keystrokeSpeed) {
                    ForEach(KeystrokeSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                Text(settings.keystrokeSpeed.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Confirm before typing more than \(settings.keystrokeWarnThreshold) characters",
                    value: $settings.keystrokeWarnThreshold,
                    in: 200...20000,
                    step: 200
                )
                Text("The \"Send as keystrokes\" action prompts before typing a clip this long.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper(
                    "Keep at most \(settings.maxHistoryItems) items",
                    value: $settings.maxHistoryItems,
                    in: 50...10000,
                    step: 50
                )
                Text("Clips in categories never count against the cap and survive Clear Unpinned History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Clippy at login", isOn: $launchAtLogin)
                    .disabled(!isRunningFromBundle)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if !isRunningFromBundle {
                    Text("Available when running the bundled Clippy.app (scripts/make-app.sh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Only font families that are installed on this machine.
    private var availableFamilies: [PanelFontFamily] {
        PanelFontFamily.allCases.filter { $0.isAvailable }
    }

    var body: some View {
        Form {
            // MARK: Theme
            Section("Theme") {
                Picker("Theme", selection: $settings.themePreset) {
                    ForEach(ThemePreset.selectable) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                ThemeSwatchStrip(tokens: settings.theme, themeName: settings.themePreset.label)

                Picker("System appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.themePreset != .system)
                if settings.themePreset != .system {
                    Text("Light/dark is set by the chosen theme. Pick \"Match system\" to follow macOS instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Accent color")
                    HStack(spacing: 8) {
                        ForEach(AccentTheme.allCases) { theme in
                            accentSwatch(theme)
                        }
                    }
                    Text("Applies on top of any theme. Used for selection, links, and the pin marker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Transparency
            Section("Transparency") {
                LabeledContent("Opacity: \(Int(settings.panelOpacity * 100))") {
                    Slider(value: $settings.panelOpacity, in: 0.3...1.0, step: 0.05)
                }
                Text("100% is fully solid. Lower values let the desktop show through a blur behind the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Custom colors (only when the Custom theme is selected)
            if settings.themePreset == .custom {
                Section("Custom colors") {
                    customColorRow("Text (primary)", $settings.customTextPrimaryHex)
                    customColorRow("Text (secondary)", $settings.customTextSecondaryHex)
                    customColorRow("Accent", $settings.customAccentHex)
                    customColorRow("Card inner surface", $settings.customCardSurfaceHex)
                    customColorRow("Card border", $settings.customCardBorderHex)
                    customColorRow("Scroll area background", $settings.customScrollBgHex)
                    customColorRow("Panel background", $settings.customPanelHex)
                    customColorRow("Header bar", $settings.customHeaderHex)
                    customColorRow("Footer bar", $settings.customFooterHex)
                    customColorRow("Category sidebar", $settings.customSidebarHex)
                    // Scrollbars and the text caret are drawn by AppKit and only
                    // come in light/dark, so they follow this toggle rather than
                    // an arbitrary hex.
                    Toggle("Dark scrollbars and caret", isOn: $settings.customIsDark)
                    HStack {
                        Button("Copy current theme") { settings.seedCustomFromActive() }
                        Button("Reset to light") { settings.resetCustomColors() }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }

            // MARK: Cards
            Section("Cards") {
                Picker("Card style", selection: $settings.cardStyle) {
                    ForEach(CardStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("Card color", selection: $settings.cardColorMode) {
                    ForEach(CardColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("\"By source app\" tints each card with the app icon's dominant color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Tint strength slider only makes a visible difference for Filled and Bordered.
                if settings.cardStyle != .plain {
                    LabeledContent("Color tint: \(settings.cardTintStrength)%") {
                        Slider(
                            value: Binding(
                                get: { Double(settings.cardTintStrength) },
                                set: { settings.cardTintStrength = Int($0) }
                            ),
                            in: 0...20,
                            step: 1
                        )
                    }
                }

                Toggle("High-contrast card text", isOn: $settings.highContrastCardText)
                Text("Uses primary label color on both title and preview text instead of subdued gray.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show app icons on cards", isOn: $settings.showAppIcons)
                Toggle("Group clips under date headers", isOn: $settings.showSectionHeaders)
            }

            // MARK: Typography
            Section("Typography") {
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(availableFamilies) { family in
                        Text(family.label).tag(family)
                    }
                }

                LabeledContent("Size: \(settings.fontSizeBase) pt") {
                    Slider(
                        value: Binding(
                            get: { Double(settings.fontSizeBase) },
                            set: { settings.fontSizeBase = Int($0) }
                        ),
                        in: 11...16,
                        step: 1
                    )
                }
                Text("Applies to clip titles, preview text, and sidebar labels. The settings window uses the system font.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Panel size and position
            Section("Panel size and position") {
                Picker("Open at", selection: $settings.positionMode) {
                    ForEach(PanelPositionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                LabeledContent("Width: \(Int(settings.panelWidth)) pt") {
                    Slider(value: $settings.panelWidth, in: 300...800, step: 20)
                }
                LabeledContent("Height: \(Int(settings.panelHeight)) pt") {
                    Slider(value: $settings.panelHeight, in: 280...900, step: 20)
                }
                Toggle("Remember last panel size", isOn: $settings.rememberPanelSize)
            }
        }
        .formStyle(.grouped)
    }

    private func accentSwatch(_ theme: AccentTheme) -> some View {
        let isSelected = settings.accentTheme == theme
        return Button {
            settings.accentTheme = theme
        } label: {
            Circle()
                .fill(theme.color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 2)
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(theme.label)
    }

    /// One editable surface color: a hex field plus the macOS color wheel, both
    /// bound to the same stored hex string so either updates the other.
    private func customColorRow(_ title: String, _ hex: Binding<String>) -> some View {
        CustomColorRow(title: title, hex: hex)
    }
}

/// A hex color field plus the macOS color wheel, both bound to the same stored
/// hex string. The text field validates on commit (not per keystroke) so an
/// invalid entry never repaints the app the fallback magenta: a bad value is
/// rejected and flagged inline instead of being written back to settings.
private struct CustomColorRow: View {
    let title: String
    let hex: Binding<String>

    /// Local editable copy so keystrokes do not write straight through to the
    /// stored hex (which would repaint live with partial/invalid input).
    @State private var draft: String = ""
    @State private var isInvalid = false

    private var color: Binding<Color> {
        Binding(
            get: { Color(themeHex: hex.wrappedValue) },
            set: { newColor in
                let value = newColor.themeHexString
                hex.wrappedValue = value
                draft = value
                isInvalid = false
            }
        )
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    TextField("#RRGGBB", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 92)
                        .foregroundStyle(isInvalid ? Color.red : Color.primary)
                        .onSubmit { commit() }
                    ColorPicker("", selection: color, supportsOpacity: false)
                        .labelsHidden()
                }
                if isInvalid {
                    Text("Enter a hex color like #1F2328.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { draft = hex.wrappedValue }
        // Keep the field in sync when the stored value changes elsewhere
        // (color wheel, Copy current theme, Reset to light).
        .onChange(of: hex.wrappedValue) { _, newValue in
            if newValue != draft { draft = newValue; isInvalid = false }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // NSColor(themeHex:) returns nil for anything that is not a valid
        // #RGB/#RRGGBB/#RRGGBBAA value, so it doubles as the validity check.
        guard NSColor(themeHex: trimmed) != nil else {
            isInvalid = true
            return
        }
        isInvalid = false
        let normalized = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
        hex.wrappedValue = normalized
        draft = normalized
    }
}

/// Five-swatch preview of the active theme (panel, card, two text tones, accent)
/// so the user sees a palette change before opening the panel.
private struct ThemeSwatchStrip: View {
    let tokens: ThemeTokens
    let themeName: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color)
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        // Decorative swatches carry no per-rectangle meaning, so collapse them
        // into one element that announces the active theme to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme preview: \(themeName)")
    }

    private var swatches: [Color] {
        [tokens.panel, tokens.cardSurface, tokens.textSecondary, tokens.textPrimary, tokens.accent]
    }
}

// MARK: - Capture

private struct CaptureSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var ignoredAppsText = AppSettings.shared.ignoredBundleIDs.joined(separator: "\n")
    @State private var ignoredAppsError: String?
    @FocusState private var ignoredAppsFocused: Bool
    @State private var soundVolumeSlider: Double = Double(AppSettings.shared.captureSoundVolume)

    private var tokens: ThemeTokens { settings.theme }

    /// Distinct catalog groups, in first-seen order, for the sectioned picker.
    private var soundGroups: [String] {
        var seen = Set<String>()
        return SoundCatalog.options.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                LabeledContent("Polling interval: \(Int(settings.pollingIntervalMs)) ms") {
                    Slider(value: $settings.pollingIntervalMs, in: 100...1000, step: 50)
                }
                Text("Lower is more responsive; higher uses less idle CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Images") {
                Toggle("Capture copied images", isOn: $settings.captureImages)
                Stepper(
                    "Largest image to keep: \(settings.maxImageSizeMB) MB",
                    value: $settings.maxImageSizeMB,
                    in: 1...100
                )
                Text("Bigger copies are ignored to keep the history database lean.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                Toggle("Play sound on capture", isOn: $settings.captureSoundEnabled)

                LabeledContent("Sound") {
                    HStack(spacing: 8) {
                        Picker("Sound", selection: $settings.captureSoundID) {
                            ForEach(soundGroups, id: \.self) { group in
                                Section(group) {
                                    ForEach(SoundCatalog.options.filter { $0.group == group }) { option in
                                        Text(option.label).tag(option.id)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        // Audition immediately on selection change, the way the
                        // macOS Sound preference pane does.
                        .onChange(of: settings.captureSoundID) { _, id in
                            SoundPlayer.play(id: id, volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume))
                        }

                        // Preview button: plays the selected sound at the
                        // current volume so the user can audition without saving.
                        Button {
                            SoundPlayer.play(
                                id: settings.captureSoundID,
                                volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume)
                            )
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Preview selected sound")
                    }
                }
                .disabled(!settings.captureSoundEnabled)

                LabeledContent("Volume: \(settings.captureSoundVolume)%") {
                    Slider(
                        value: $soundVolumeSlider,
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { editing in
                            // Commit on release; preview so the user can hear
                            // the level change immediately.
                            if !editing {
                                settings.captureSoundVolume = Int(soundVolumeSlider)
                                SoundPlayer.play(
                                    id: settings.captureSoundID,
                                    volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume)
                                )
                            }
                        }
                    )
                }
                .disabled(!settings.captureSoundEnabled)
            }

            Section("Ignored apps") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bundle IDs, one per line (e.g. com.apple.keychainaccess)")
                        .font(.caption)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $ignoredAppsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 90)
                            .cornerRadius(6)
                            .focused($ignoredAppsFocused)
                            // Commit on focus loss instead of per keystroke so a
                            // half-typed bundle ID is not persisted, and so invalid
                            // entries can be flagged rather than silently kept.
                            .onChange(of: ignoredAppsFocused) { _, focused in
                                if !focused { commitIgnoredApps() }
                            }
                        if ignoredAppsText.isEmpty {
                            Text("com.apple.keychainaccess\ncom.1password.1password")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(tokens.cardBorder, lineWidth: 1)
                    )
                    if let ignoredAppsError {
                        Text(ignoredAppsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Always skipped") {
                Label(
                    "Concealed clipboard items (password managers such as 1Password and Bitwarden)",
                    systemImage: "key.slash"
                )
                Label("Transient and auto-generated clipboard writes", systemImage: "clock.badge.xmark")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }

    /// Parse the editor on focus loss: persist only well-formed bundle IDs and
    /// report any rejected lines inline rather than storing garbage silently.
    private func commitIgnoredApps() {
        let lines = ignoredAppsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let valid = lines.filter(Self.isPlausibleBundleID)
        let invalid = lines.filter { !Self.isPlausibleBundleID($0) }
        settings.ignoredBundleIDs = valid
        ignoredAppsError = invalid.isEmpty
            ? nil
            : "Ignored invalid bundle ID(s): \(invalid.joined(separator: ", "))"
    }

    /// A reverse-DNS bundle ID is dot-separated alphanumeric/hyphen labels, at
    /// least two of them (e.g. com.apple.finder). This rejects obvious typos
    /// such as spaces, leading dots, or single-word entries without coupling to
    /// any external validator.
    private static func isPlausibleBundleID(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.allSatisfy { label in
            !label.isEmpty && CharacterSet(charactersIn: String(label)).isSubset(of: allowed)
        }
    }
}

// MARK: - Integrations

private struct AISettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mcpController = McpServerController.shared
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var mcpTestResult: String?
    @State private var mcpTesting = false
    @State private var mcpInstallResult: String?
    @State private var mcpInstalledClients: Set<McpClient> = []

    var body: some View {
        Form {
            Section("AI features") {
                Toggle("Enable AI and agentic features", isOn: $settings.aiEnabled)
                Text("Clippy can suggest titles, rewrite text, suggest a category, and draft new clips using the provider below. Proposed changes are shown for your approval before anything is written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Model", text: $settings.aiModel,
                          prompt: Text(settings.aiProvider.defaultModel))
                Text(settings.aiProvider.modelHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Endpoint URL", text: $settings.aiBaseURL,
                          prompt: Text(settings.aiProvider.defaultBaseURL))
                if settings.aiProvider == .azureFoundry {
                    TextField("API version", text: $settings.aiAzureAPIVersion)
                }
                if settings.aiProvider.needsAPIKey {
                    SecureField("API key", text: $apiKey, prompt: Text("Paste, then Save"))
                    HStack(spacing: 8) {
                        Button("Save key") { saveKey() }
                            .disabled(apiKey.isEmpty)
                        Button("Clear") { clearKey() }
                        if !keyStatus.isEmpty {
                            Label(keyStatus, systemImage: keyStatus.hasPrefix("Key") ? "checkmark.circle.fill" : "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(keyStatus.hasPrefix("Key") ? Color.green : Color.secondary)
                        }
                    }
                } else {
                    Text("Ollama runs locally and needs no API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 8) {
                    Button(testing ? "Testing..." : "Test AI connection") { test() }
                        .disabled(testing || !settings.aiEnabled)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Automation") {
                Toggle("Auto-suggest a title for new clips", isOn: $settings.aiAutoSuggestTitles)
                    .disabled(!settings.aiEnabled)
                Text("The only action applied automatically. Everything else asks first, and titles can be edited or cleared anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                AIActionsManagerView()
                    .frame(height: 220)
            }
            .disabled(!settings.aiEnabled)

            Section("Agent and tools") {
                Toggle("Allow AI to run my scripts", isOn: $settings.aiAgentAllowScripts)
                    .disabled(!settings.aiEnabled)
                Text("When on, the AI Assistant can list and run your saved scripts. You will be shown a confirmation prompt each time before a script runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow AI to execute generated code", isOn: $settings.aiAgentAllowCodeExecution)
                    .disabled(!settings.aiEnabled)
                Text("When on, the AI Assistant can write and execute code. The code runs as you with full environment access and a 30-second timeout. You will be shown the code and asked to confirm before each run. Both options are off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("MCP integration") {
                Toggle("Enable Clippy MCP server", isOn: $settings.mcpEnabled)
                Text("Runs a local server so AI tools (Claude, Copilot) can read and search your clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", value: $settings.mcpPort, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        let portFree = mcpController.isPortFree(settings.mcpPort)
                        Label(portFree ? "Port \(settings.mcpPort) is available"
                                       : "Port \(settings.mcpPort) is in use",
                              systemImage: portFree ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(portFree ? Color.green : Color.orange)
                    }
                }
                .disabled(!settings.mcpEnabled)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(mcpStatusColor)
                            .frame(width: 8, height: 8)
                        Text(mcpController.status.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Install for...") {
                ForEach(McpClient.allCases) { client in
                    HStack {
                        if mcpInstalledClients.contains(client) {
                            Label(client.displayName, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(client.displayName, systemImage: "circle")
                        }
                        Spacer()
                        Button("Install") {
                            let result = McpInstallService.install(client, port: settings.mcpPort)
                            switch result {
                            case .success(let msg):
                                mcpInstallResult = msg
                                refreshInstalledClients()
                            case .failure(let err):
                                mcpInstallResult = err.localizedDescription
                            }
                        }
                        .disabled(!settings.mcpEnabled)
                    }
                }
                if let mcpInstallResult {
                    Text(mcpInstallResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !settings.mcpEnabled {
                    Text("Enable the MCP server above before installing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Button(mcpTesting ? "Testing..." : "Test MCP server") {
                        mcpTest()
                    }
                    .disabled(mcpTesting || !mcpController.status.isRunning)
                    if let mcpTestResult {
                        Text(mcpTestResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshKeyStatus()
            refreshInstalledClients()
        }
        .onChange(of: settings.aiProvider) { refreshKeyStatus() }
    }

    private func refreshKeyStatus() {
        apiKey = ""
        guard settings.aiProvider.needsAPIKey else { keyStatus = ""; return }
        keyStatus = KeychainStore.shared.has(account: settings.aiProvider.keychainAccount)
            ? "Key stored in Keychain."
            : "No key saved."
    }

    private func saveKey() {
        let ok = KeychainStore.shared.write(apiKey, account: settings.aiProvider.keychainAccount)
        keyStatus = ok ? "Key saved to Keychain." : "Could not save to Keychain."
        apiKey = ""
    }

    private func clearKey() {
        KeychainStore.shared.delete(account: settings.aiProvider.keychainAccount)
        refreshKeyStatus()
    }

    private var mcpStatusColor: Color {
        switch mcpController.status {
        case .running:   return .green
        case .starting:  return .yellow
        case .stopped:   return .secondary
        case .portInUse: return .orange
        case .failed:    return .red
        }
    }

    private func refreshInstalledClients() {
        var found = Set<McpClient>()
        for client in McpClient.allCases {
            if McpInstallService.isInstalled(client) { found.insert(client) }
        }
        mcpInstalledClients = found
    }

    private func mcpTest() {
        mcpTesting = true
        mcpTestResult = nil
        McpServerController.shared.testConnection { result in
            switch result {
            case .success(let count):
                mcpTestResult = count > 0
                    ? "Connected. \(count) tool\(count == 1 ? "" : "s") available."
                    : "Connected."
            case .failure(let err):
                mcpTestResult = err.localizedDescription
            }
            mcpTesting = false
        }
    }

    private func test() {
        testing = true
        testResult = nil
        switch AIService.fromSettings() {
        case .failure(let error):
            testResult = error.localizedDescription
            testing = false
        case .success(let service):
            Task {
                do {
                    let proposal = try await service.suggestTitle(
                        forText: "The quick brown fox jumps over the lazy dog.")
                    await MainActor.run {
                        testResult = "Connected. Sample title: \(proposal.proposed)"
                        testing = false
                    }
                } catch {
                    await MainActor.run {
                        testResult = error.localizedDescription
                        testing = false
                    }
                }
            }
        }
    }
}

private struct IntegrationsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var cloud = ICloudSyncService.shared
    @State private var exportResult: String?
    @State private var archiveResult: String?

    var body: some View {
        Form {
            Section("Categories and pins") {
                LabeledContent("Pinned archive") {
                    HStack {
                        Button("Export clippy.toml...") { exportTOML() }
                        Button("Import clippy.toml...") { importTOML() }
                    }
                }
                if let archiveResult {
                    Text(archiveResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("clippy.toml is a human-readable file of every category (name, color, icon, order) and the clips pinned into it. Edit it in any text editor and re-import to make bulk changes. Importing is non-destructive: it adds and updates, never clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Export history") {
                    Button("Export as JSON...") { exportJSON() }
                }
                if let exportResult {
                    Text(exportResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Database") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ClipDatabase.shared.databaseURL])
                    }
                }
                Text("Everything is stored locally in a SQLite file you can inspect or back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("1Password") {
                Toggle("Show 1Password vault in the sidebar", isOn: $settings.onePasswordEnabled)
                TextField("Vault name", text: $settings.onePasswordVault, prompt: Text("Clippy"))
                Toggle("Auto-clear clipboard after copying a secret",
                       isOn: $settings.onePasswordAutoClearClipboard)
                if settings.onePasswordAutoClearClipboard {
                    Stepper(
                        "Clear after \(settings.onePasswordAutoClearDelaySecs) seconds",
                        value: $settings.onePasswordAutoClearDelaySecs,
                        in: 10...600,
                        step: 10
                    )
                    Text("The pasteboard is only cleared if it still holds the copied secret (no effect if you have already pasted or copied something else).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: OnePasswordService.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(OnePasswordService.isInstalled ? .green : .secondary)
                    Text(OnePasswordService.isInstalled
                         ? "1Password CLI (op) found."
                         : "1Password CLI (op) not found. Enable it in 1Password 8 > Developer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Secrets in this vault appear as a sidebar category. Expanding an item shows all its fields; each field can be copied individually. Concealed values are revealed in-place with a toggle. TOTP codes are fetched fresh on each copy. Nothing is recorded in history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iCloud sync") {
                Toggle("Sync clips and categories through iCloud Drive", isOn: $settings.iCloudSyncEnabled)
                    .onChange(of: settings.iCloudSyncEnabled) {
                        if settings.iCloudSyncEnabled { ICloudSyncService.shared.startIfEnabled() }
                    }
                HStack {
                    Button(cloud.syncing ? "Syncing..." : "Sync now") {
                        Task { await ICloudSyncService.shared.sync() }
                    }
                    .disabled(!settings.iCloudSyncEnabled || cloud.syncing || !cloud.isAvailable)
                    // The service reports a write failure through `status` as a
                    // "Sync failed: ..." string; flag that inline in red the same
                    // way the launch-at-login error is shown, instead of letting
                    // it read as ordinary secondary status text.
                    Text(cloud.isAvailable ? cloud.status : "iCloud Drive is off on this Mac.")
                        .font(.caption)
                        .foregroundStyle(syncStatusFailed ? Color.red : Color.secondary)
                }
                Text("Writes your categories and pinned clips to an iCloud Drive file (iCloud Drive > Clippy) that your other Macs read on sync. Non-destructive: it merges, never clears. No CloudKit, no special entitlement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    /// True when the iCloud service has reported a sync write failure. The
    /// service surfaces failures by setting `status` to a "Sync failed:" string,
    /// so match that prefix rather than adding a property to that service.
    private var syncStatusFailed: Bool {
        cloud.isAvailable && cloud.status.hasPrefix("Sync failed")
    }

    /// Shared NSSavePanel scaffold. Returns the result string to display, or nil
    /// when the user cancelled (so the caller leaves the prior message intact).
    private func runSavePanel(name: String, types: [UTType],
                              _ body: (URL) throws -> String) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try body(url) }
        catch { return "Export failed: \(error.localizedDescription)" }
    }

    /// Shared NSOpenPanel scaffold. Same cancel semantics as runSavePanel.
    private func runOpenPanel(types: [UTType],
                              _ body: (URL) throws -> String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try body(url) }
        catch { return "Import failed: \(error.localizedDescription)" }
    }

    private func exportTOML() {
        let result = runSavePanel(name: "clippy.toml",
                                  types: [UTType(filenameExtension: "toml") ?? .plainText]) { url in
            let toml = try ClippyArchive.exportTOML(from: ClipDatabase.shared)
            try toml.write(to: url, atomically: true, encoding: .utf8)
            return "Exported categories and pinned clips to \(url.lastPathComponent)."
        }
        if let result { archiveResult = result }
    }

    private func importTOML() {
        let result = runOpenPanel(types: [UTType(filenameExtension: "toml") ?? .plainText, .plainText, .text]) { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let summary = try ClippyArchive.importTOML(text, into: ClipDatabase.shared)
            var message = "Imported \(summary.categories) categories and \(summary.clips) clips."
            if summary.skippedImages > 0 {
                message += " Skipped \(summary.skippedImages) image(s) whose files were missing."
            }
            return message
        }
        if let result { archiveResult = result }
    }

    private func exportJSON() {
        struct ExportClip: Encodable {
            let text: String
            let kind: String
            let mediaFile: String?
            let sourceApp: String?
            let sourceBundleID: String?
            let createdAt: Date
            let categories: [String]
        }
        struct ExportDocument: Encodable {
            let note: String
            let clips: [ExportClip]
        }

        let result = runSavePanel(name: "clippy-export.json", types: [.json]) { url in
            let database = ClipDatabase.shared
            let categories = try database.categories()
            let membership = try database.membershipMap()
            let nameByID = Dictionary(
                uniqueKeysWithValues: categories.compactMap { category in
                    category.id.map { ($0, category.name) }
                }
            )
            let clips = try database.allClips().map { clip in
                ExportClip(
                    text: clip.contentText,
                    kind: clip.contentKind.rawValue,
                    mediaFile: clip.mediaFilename.map { database.media.url(for: $0).path },
                    sourceApp: clip.sourceAppName,
                    sourceBundleID: clip.sourceAppBundleID,
                    createdAt: clip.createdAt,
                    categories: (clip.id.flatMap { membership[$0] } ?? [])
                        .compactMap { nameByID[$0] }
                        .sorted()
                )
            }
            let document = ExportDocument(
                note: "Image clips reference PNG files under the Clippy media folder; copy them separately if you need a portable backup.",
                clips: clips
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url)
            return "Exported \(clips.count) clips to \(url.lastPathComponent)."
        }
        if let result { exportResult = result }
    }
}

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "doc.on.clipboard") }
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 540, height: 560)
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
                Text("Custom hotkey recording is planned; the binding is fixed in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pasting") {
                Toggle("Paste as plain text by default", isOn: $settings.pastePlainTextByDefault)
                Toggle("Move pasted item to top of history", isOn: $settings.movePastedItemToTop)
                Text("Shift+Return in the panel always pastes in the non-default mode.")
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
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Accent color")
                    HStack(spacing: 8) {
                        ForEach(AccentTheme.allCases) { theme in
                            accentSwatch(theme)
                        }
                    }
                }
            }

            // MARK: Background
            Section("Background") {
                Picker("Panel background", selection: $settings.panelMaterial) {
                    ForEach(PanelMaterialStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Text("\"Solid\" uses the standard window color with full contrast. Glass options apply a blur effect behind the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}

// MARK: - Capture

private struct CaptureSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var ignoredAppsText = AppSettings.shared.ignoredBundleIDs.joined(separator: "\n")
    @State private var soundVolumeSlider: Double = Double(AppSettings.shared.captureSoundVolume)

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
                        Picker("Sound", selection: $settings.captureSoundName) {
                            ForEach(CaptureSound.allCases) { sound in
                                Text(sound.label).tag(sound)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        // Preview button: plays the selected sound at the
                        // current volume so the user can audition without saving.
                        Button {
                            SoundPlayer.play(
                                settings.captureSoundName,
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
                                    settings.captureSoundName,
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
                    TextEditor(text: $ignoredAppsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 90)
                        .onChange(of: ignoredAppsText) { _, newValue in
                            settings.ignoredBundleIDs = newValue
                                .split(whereSeparator: \.isNewline)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
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
}

// MARK: - Integrations

private struct IntegrationsSettingsTab: View {
    @State private var exportResult: String?

    var body: some View {
        Form {
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

            Section("AI and automation (planned)") {
                plannedRow(
                    "MCP server",
                    detail: "Claude Code and Claude Desktop will be able to search, read, and set clips."
                )
                plannedRow(
                    "Local REST API",
                    detail: "Loopback-only HTTP endpoint with a Keychain bearer token, for Shortcuts and scripts."
                )
                plannedRow(
                    "Sync",
                    detail: "User-controlled: encrypted file in a folder you choose, or CloudKit private database."
                )
                plannedRow(
                    "Encryption at rest",
                    detail: "SQLCipher with the key in your Keychain."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func plannedRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("Planned")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clippy-export.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
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
            exportResult = "Exported \(clips.count) clips to \(url.lastPathComponent)."
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
}

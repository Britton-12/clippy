import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem!

    // Sparkle needs a packaged .app whose Info.plist carries SUFeedURL; when
    // running unbundled (swift run, smoke tests) leave the updater unstarted
    // so it stays inert and the menu item validates to disabled.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private let database = ClipDatabase.shared
    private lazy var store = ClipStore(database: database)
    private lazy var monitor = ClipboardMonitor(database: database)
    private lazy var pasteService = PasteService(monitor: monitor)
    private lazy var panelController = PanelController(store: store)
    private let editorController = EditorWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        monitor.start()

        // Crash between media write and row insert leaves orphan files;
        // sweep them off the main thread at launch.
        DispatchQueue.global(qos: .utility).async {
            let referenced = (try? ClipDatabase.shared.referencedMediaFilenames()) ?? []
            ClipDatabase.shared.media.sweepOrphans(referencedFilenames: referenced)
        }

        HotKeyCenter.shared.handler = { [weak self] in
            self?.panelController.toggle()
        }
        HotKeyCenter.shared.registerDefaultHotKey()

        panelController.onPaste = { [weak self] clip, asPlainText in
            guard let self else { return }
            self.panelController.hide()
            self.pasteService.paste(clip, asPlainText: asPlainText)
        }
        panelController.onEdit = { [weak self] clip in
            guard let self else { return }
            // Panel stays open while the editor is visible; only item-click,
            // hotkey toggle, and Escape are valid close triggers.
            self.editorController.open(clip: clip) { newText in
                self.store.updateText(of: clip, to: newText)
            }
        }
        panelController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }

        // Caret positioning and the simulated Cmd-V both need Accessibility.
        // Prompt once; everything else degrades gracefully without it.
        if !CaretLocator.isTrusted {
            CaretLocator.requestPermission()
        }

        // Debug aids: open the panel right after launch, or render it to a
        // PNG and exit (used by UI smoke tests that cannot press the global
        // hotkey).
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panelController.show()
            }
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--screenshot"),
           CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.panelController.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.panelController.snapshotPanel(to: url)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MascotStatusIcon.image()
        statusItem.button?.wantsLayer = true

        // Bounce the mascot the instant a clip is captured, in sync with the
        // capture sound (both fire off the same .clippyDidCapture event).
        NotificationCenter.default.addObserver(
            forName: .clippyDidCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            MascotStatusIcon.bounce(button)
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Clipboard", action: #selector(openPanel), keyEquivalent: "v")
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self
        menu.addItem(openItem)

        pauseMenuItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let clearItem = NSMenuItem(title: "Clear Unpinned History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Quit Clippy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func openPanel() {
        panelController.show()
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        pauseMenuItem.state = monitor.isPaused ? .on : .off
        // Dim the mascot while capture is paused so the state is visible at a
        // glance without swapping to a different glyph.
        statusItem.button?.alphaValue = monitor.isPaused ? 0.4 : 1.0
        statusItem.button?.toolTip = monitor.isPaused ? "Clippy (paused)" : "Clippy"
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Clippy Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All unpinned clips will be deleted. Pinned clips are kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            try? database.deleteUnclassifiedClips()
        }
    }
}

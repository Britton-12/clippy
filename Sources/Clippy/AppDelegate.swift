import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem!
    private let scriptsMenu = NSMenu()

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

        // Kick off an iCloud Drive sync if the user has enabled it (safe no-op
        // otherwise; never touches CloudKit, so it cannot crash on launch).
        ICloudSyncService.shared.startIfEnabled()

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
            // hotkey toggle, and Escape are valid close triggers. The editor now
            // saves directly through the store (text edits, image edits, title).
            self.editorController.open(clip: clip, store: self.store)
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
        // Proves the iCloud sync path runs end to end (file write/read, archive
        // round-trip) without crashing, against a temp folder instead of the real
        // iCloud Drive. Used to validate that enabling sync can never crash.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--icloud-selftest"),
           CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            let service = ICloudSyncService(rootOverride: dir)
            Task { @MainActor in
                await service.sync(force: true)
                print("ICLOUD_SELFTEST status=\(service.status)")
                let synced = dir.appendingPathComponent("Clippy/clippy-sync.toml")
                print("ICLOUD_SELFTEST file_exists=\(FileManager.default.fileExists(atPath: synced.path))")
                NSApp.terminate(nil)
            }
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--screenshot-settings"),
           CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            let path = CommandLine.arguments[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    if let view = self?.settingsWindow?.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusBarIcon.image()
        statusItem.button?.wantsLayer = true

        // Bounce the icon the instant a clip is captured, in sync with the
        // capture sound (both fire off the same .clippyDidCapture event).
        NotificationCenter.default.addObserver(
            forName: .clippyDidCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            StatusBarIcon.bounce(button)
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

        // Stored scripts, runnable straight from the menu bar. The submenu is
        // rebuilt each time it opens (scriptsMenu is its own delegate's target).
        let scriptsItem = NSMenuItem(title: "Run Script", action: nil, keyEquivalent: "")
        scriptsMenu.delegate = self
        scriptsItem.submenu = scriptsMenu
        menu.addItem(scriptsItem)

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
        // Filled clipboard signals paused; outline signals capturing.
        statusItem.button?.image = StatusBarIcon.image(paused: monitor.isPaused)
        statusItem.button?.toolTip = monitor.isPaused ? "Clippy (paused)" : "Clippy"
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Clippy Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
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

    // MARK: - Scripts

    @objc private func runScriptFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let script = ScriptStore.shared.script(id: id) else { return }
        let input = script.feedsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        Task { @MainActor in
            let result = await ScriptRunner.run(script, input: input)
            self.presentScriptResult(script, result)
        }
    }

    @MainActor
    private func presentScriptResult(_ script: Script, _ result: ScriptResult) {
        // Auto-offering output as a clip: just place it on the pasteboard, which
        // the monitor captures into history like any other copy.
        if script.outputToClipboard, result.succeeded, !result.stdout.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result.stdout, forType: .string)
        }
        let alert = NSAlert()
        alert.messageText = result.timedOut
            ? "\(script.name) timed out"
            : "\(script.name) finished (exit \(result.exitCode))"
        let body = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n--- stderr ---\n")
        alert.informativeText = String(body.prefix(1500)).isEmpty ? "No output." : String(body.prefix(1500))
        alert.alertStyle = result.succeeded ? .informational : .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === scriptsMenu else { return }
        menu.removeAllItems()
        let scripts = ScriptStore.shared.scripts
        if scripts.isEmpty {
            let empty = NSMenuItem(title: "No scripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            let manage = NSMenuItem(title: "Manage in Settings...", action: #selector(openSettings), keyEquivalent: "")
            manage.target = self
            menu.addItem(manage)
            return
        }
        for script in scripts {
            let item = NSMenuItem(title: script.name.isEmpty ? "Untitled" : script.name,
                                  action: #selector(runScriptFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = script.id
            menu.addItem(item)
        }
    }
}

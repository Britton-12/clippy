import AppKit
import Darwin
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem!
    private let scriptsMenu = NSMenu()
    private let keystrokeService = KeystrokeService()

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

    // Strong reference required: a DispatchSourceMemoryPressure is suspended
    // and released if the owner goes away, silently disabling the safeguard.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        monitor.start()

        // Log launch with version so post-mortem analysis can correlate log
        // lines to the exact binary that was running when a problem occurred.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        ClippyLog.info("Clippy launched — version \(version) (\(build))", category: ClippyLog.lifecycle)

        // Uncaught-exception handler: write name/reason/stack to the log file
        // synchronously before the process dies so the crash is always on disk,
        // not only in the os_log ring buffer which may roll over before diagnosis.
        NSSetUncaughtExceptionHandler { exception in
            let msg = "UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "(no reason)") | \(exception.callStackSymbols.prefix(20).joined(separator: " | "))"
            ClippyLog.syncWrite(msg, level: "FATAL")
        }

        // Memory-pressure source: the OS notifies us before it starts killing
        // processes. On warning we free the thumbnail cache (the primary 4 GB
        // cause); on critical we also trim the in-memory clip array so SwiftUI
        // can release its retained Clip values and backing storage.
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = pressureSource.data
            let rss = Self.residentMemoryMB()
            if event.contains(.critical) {
                ClippyLog.error("Memory pressure CRITICAL — RSS ~\(rss) MB; purging cache + trimming clips",
                                category: ClippyLog.lifecycle)
                ClipCardView.purgeThumbnailCache()
                self.store.trimResident()
            } else if event.contains(.warning) {
                ClippyLog.info("Memory pressure WARNING — RSS ~\(rss) MB; purging thumbnail cache",
                               category: ClippyLog.lifecycle)
                ClipCardView.purgeThumbnailCache()
            }
        }
        pressureSource.resume()
        memoryPressureSource = pressureSource

        // Crash between media write and row insert leaves orphan files;
        // sweep them off the main thread at launch.
        DispatchQueue.global(qos: .utility).async {
            let referenced = (try? ClipDatabase.shared.referencedMediaFilenames()) ?? []
            ClipDatabase.shared.media.sweepOrphans(referencedFilenames: referenced)
        }

        // Kick off an iCloud Drive sync if the user has enabled it (safe no-op
        // otherwise; never touches CloudKit, so it cannot crash on launch).
        ICloudSyncService.shared.startIfEnabled()

        // Start the MCP server if the user has enabled it, and wire up
        // live reactions to settings changes.
        McpServerController.shared.syncWithSettings()

        HotKeyCenter.shared.handler = { [weak self] in
            self?.panelController.toggle()
        }
        HotKeyCenter.shared.registerDefaultHotKey()

        panelController.onPaste = { [weak self] clip, asPlainText in
            guard let self else { return }
            // hideAfterPaste=false lets the panel stay open for rapid multi-paste.
            // panelPinned suppresses all auto-hide triggers.
            let s = AppSettings.shared
            if s.hideAfterPaste && !s.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            self.pasteService.paste(clip, asPlainText: asPlainText)
        }
        panelController.onPasteMany = { [weak self] clips, combined, asPlainText in
            guard let self else { return }
            let s = AppSettings.shared
            if s.hideAfterPaste && !s.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            if combined {
                self.pasteService.pasteCombined(clips, asPlainText: asPlainText)
            } else {
                self.pasteService.pasteSequence(clips, asPlainText: asPlainText)
            }
        }
        panelController.onPasteFile = { [weak self] clip, move in
            guard let self else { return }
            let s = AppSettings.shared
            if s.hideAfterPaste && !s.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            self.pasteService.pasteFile(clip, move: move)
        }
        panelController.onPrimary = { [weak self] clip in
            guard let self else { return }
            let s = AppSettings.shared
            if s.hideAfterPaste && !s.panelPinned { self.panelController.hide() }
            if s.clickCopyOnly {
                self.pasteService.copy(clip, asPlainText: s.pastePlainTextByDefault)
            } else {
                self.panelController.restoreFocusToPreviousApp()
                self.pasteService.paste(clip, asPlainText: s.pastePlainTextByDefault)
            }
        }
        panelController.onSendKeystrokes = { [weak self] clip in
            guard let self else { return }
            let s = AppSettings.shared
            if s.hideAfterPaste && !s.panelPinned { self.panelController.hide() }
            // Hand keyboard focus back to the target app before typing, otherwise
            // the unicode key events land on no first responder and the system
            // beeps once per character. Write to clipboard too as a copy-fallback.
            self.panelController.restoreFocusToPreviousApp()
            self.pasteService.copy(clip, asPlainText: true)
            let text = clip.contentText
            // Slightly longer than the paste delay: re-activation has to settle
            // and the target's text field must regain first responder first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.keystrokeService.type(text)
            }
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
                ClippyLog.info("ICLOUD_SELFTEST status=\(service.status)", category: ClippyLog.sync)
                let synced = dir.appendingPathComponent("Clippy/clippy-sync.toml")
                ClippyLog.info("ICLOUD_SELFTEST file_exists=\(FileManager.default.fileExists(atPath: synced.path))",
                               category: ClippyLog.sync)
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
        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All unpinned clips will be deleted. Pinned clips are kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            try? database.deleteUnclassifiedClips()
        }
    }

    // MARK: - Main menu (restores Cmd+C/V/X/A/Z in all app windows)

    /// Assigns a minimal NSApp.mainMenu so standard editing key-equivalents can
    /// find a target through the responder chain. Without this the accessory-app
    /// activation mode leaves mainMenu nil and the system cannot dispatch Cmd+C
    /// etc. to the focused text field or text view.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App submenu (macOS requires the first item to be the app menu).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit Clippy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit submenu: Undo, Redo, then the standard clipboard verbs. All
        // editing items leave target == nil so events flow up the responder chain
        // to the first object that can handle them (NSTextView, NSTextField, etc.).
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(selectAllItem)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
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
        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClippyLog.info("Clippy shutting down cleanly", category: ClippyLog.lifecycle)
        // Ensure the node MCP server process never outlives the app.
        McpServerController.shared.stop()
    }

    // MARK: - Memory helpers

    /// Read the process's current resident set size via mach_task_basic_info.
    /// Returns 0 if the call fails (non-fatal; used only for log context).
    private static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / (1024 * 1024)
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

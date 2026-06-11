import AppKit
import SwiftUI

/// Owns the popup panel: creates it, positions it per the user's position
/// mode (caret, mouse, last position, screen center), shows and hides it.
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipStore
    private let settings = AppSettings.shared
    private var panel: PastePanel?

    var onPaste: ((Clip, Bool) -> Void)?
    var onEdit: ((Clip) -> Void)?
    var onOpenSettings: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: ClipStore) {
        self.store = store
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = ensurePanel()
        let size = NSSize(width: settings.panelWidth, height: settings.panelHeight)

        // Fresh root view per presentation: resets search text, selection,
        // and guarantees the search field grabs focus.
        store.query = ""
        let root = ClipListView(
            store: store,
            onPaste: { [weak self] clip, asPlainText in self?.onPaste?(clip, asPlainText) },
            onEdit: { [weak self] clip in self?.onEdit?(clip) },
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                // Settings opens alongside the panel; panel stays visible.
                self?.onOpenSettings?()
            }
        )
        panel.appearance = Theme.nsAppearance(settings)
        panel.contentView = NSHostingView(rootView: root)

        // Position synchronously using the last-known or mouse anchor so the
        // panel appears immediately. For caret mode, refine the position on a
        // background thread to avoid blocking the main thread on the AX API.
        let initialFrame = fastFrame(size: size)
        panel.setFrame(initialFrame, display: false)
        panel.makeKeyAndOrderFront(nil)

        if settings.positionMode == .caret {
            repositionAtCaretAsync(panel: panel, size: size)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        settings.lastPanelOrigin = panel.frame.origin
        if settings.rememberPanelSize {
            settings.panelWidth = panel.frame.width
            settings.panelHeight = panel.frame.height
        }
        panel.orderOut(nil)
    }

    /// Debug aid for UI smoke tests: render the panel's content into a PNG.
    /// Works even when the panel lost key status, since it draws the view
    /// hierarchy directly instead of capturing the screen.
    func snapshotPanel(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Panel is intentionally persistent: focus loss does not close it.
        // The only valid close triggers are item click, hotkey toggle, and Escape.
    }

    // MARK: - Construction and placement

    private func ensurePanel() -> PastePanel {
        if let panel { return panel }
        let panel = PastePanel(
            contentRect: NSRect(x: 0, y: 0, width: settings.panelWidth, height: settings.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        // .statusBar (25) floats above every normal app window and above full-screen
        // app chrome, which satisfies the "above everything" requirement without
        // covering the system screensaver.
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 280, height: 240)
        // .canJoinAllSpaces: stays visible across space switches.
        // .fullScreenAuxiliary: renders over full-screen apps.
        // .managed (not .transient): the window manager keeps it in the current
        //   space instead of evicting it during Mission Control transitions.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Synchronous frame that never calls the AX API, safe to call on the main
    /// thread with no risk of blocking. For caret mode it uses the mouse as the
    /// initial anchor; repositionAtCaretAsync() refines it once the AX result
    /// arrives on a background thread.
    private func fastFrame(size: NSSize) -> NSRect {
        switch settings.positionMode {
        case .caret:
            // Use mouse as a cheap stand-in; async refinement follows immediately.
            return frame(anchoredTo: mouseAnchor(), size: size)
        case .mouse:
            return frame(anchoredTo: mouseAnchor(), size: size)
        case .lastPosition:
            if let origin = settings.lastPanelOrigin {
                return clamped(NSRect(origin: origin, size: size))
            }
            return centeredFrame(size: size)
        case .screenCenter:
            return centeredFrame(size: size)
        }
    }

    /// Looks up the caret rect on a background thread (AX can block) and
    /// moves the panel if the result differs meaningfully from its current
    /// position. No-ops if the panel was closed before the lookup returns.
    private func repositionAtCaretAsync(panel: PastePanel, size: NSSize) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak panel] in
            guard let self else { return }
            let caretRect = CaretLocator.caretScreenRect()
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, panel.isVisible else { return }
                let target: NSRect
                if let caret = caretRect {
                    target = self.frame(anchoredTo: caret, size: size)
                } else {
                    // AX unavailable or app blocked it; mouse anchor already set.
                    return
                }
                // Only animate if the delta is visible to the user (> 4pt).
                if abs(target.origin.x - panel.frame.origin.x) > 4
                    || abs(target.origin.y - panel.frame.origin.y) > 4 {
                    panel.setFrame(target, display: true, animate: false)
                }
            }
        }
    }

    private func mouseAnchor() -> CGRect {
        let location = NSEvent.mouseLocation
        return CGRect(x: location.x, y: location.y, width: 0, height: 0)
    }

    /// Place the panel just below the anchor rect; flip above it when there
    /// is no room, and keep everything inside the screen's visible frame.
    private func frame(anchoredTo anchor: CGRect, size: NSSize) -> NSRect {
        let visible = screen(containing: anchor.origin).visibleFrame
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - 6 - size.height)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 6
        }
        return clamped(NSRect(origin: origin, size: size), within: visible)
    }

    private func centeredFrame(size: NSSize) -> NSRect {
        let visible = screen(containing: NSEvent.mouseLocation).visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ rect: NSRect, within visible: NSRect? = nil) -> NSRect {
        let bounds = visible ?? screen(containing: rect.origin).visibleFrame
        var result = rect
        result.origin.x = max(bounds.minX + 8, min(result.origin.x, bounds.maxX - result.width - 8))
        result.origin.y = max(bounds.minY + 8, min(result.origin.y, bounds.maxY - result.height - 8))
        return result
    }

    private func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

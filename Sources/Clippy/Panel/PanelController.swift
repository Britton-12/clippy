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
                self?.hide()
                self?.onOpenSettings?()
            }
        )
        panel.appearance = settings.appearanceMode.nsAppearance
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(presentationFrame(size: size), display: false)
        panel.makeKeyAndOrderFront(nil)
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
        // Clicking anywhere else dismisses the panel, like a menu.
        hide()
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
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 280, height: 240)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        self.panel = panel
        return panel
    }

    private func presentationFrame(size: NSSize) -> NSRect {
        switch settings.positionMode {
        case .caret:
            if let caret = CaretLocator.caretScreenRect() {
                return frame(anchoredTo: caret, size: size)
            }
            // Electron hosts and apps that block AX: fall back to the mouse.
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

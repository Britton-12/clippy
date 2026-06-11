import AppKit

// Wireframe version of the Clippy mascot for the menu bar: a paperclip body
// (the doubled wire) with two eyes, drawn as a template image so macOS tints it
// to match the menu bar in light and dark. Far more legible at 18pt than the
// stock SF "clipboard" glyph, and it can bounce on each capture.
enum MascotStatusIcon {
    private static let side: CGFloat = 18

    /// The active mascot, as a template image (auto-tinted by the menu bar).
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clippy"
        return image
    }

    // MARK: - Drawing

    private static func draw() {
        let line = NSColor.black
        line.setStroke()
        line.setFill()

        // Outer paperclip wire: a tall vertical capsule.
        let outer = NSBezierPath(
            roundedRect: NSRect(x: 4.5, y: 1.8, width: 9, height: 14.4),
            xRadius: 4.5, yRadius: 4.5
        )
        outer.lineWidth = 1.5
        outer.stroke()

        // Inner wire: a shorter capsule, offset up, to read as a real paperclip.
        let inner = NSBezierPath(
            roundedRect: NSRect(x: 6.7, y: 4.4, width: 4.6, height: 9.0),
            xRadius: 2.3, yRadius: 2.3
        )
        inner.lineWidth = 1.3
        inner.stroke()

        // Two eyes near the top, the mascot's signature.
        for cx in [7.0, 11.0] {
            let eye = NSBezierPath(ovalIn: NSRect(x: cx - 1.25, y: 11.6, width: 2.5, height: 2.5))
            eye.fill()
        }
    }

    // MARK: - Bounce

    /// Squash-and-stretch hop on the status button, pivoting at its center.
    /// Called in sync with the capture sound so icon and sound fire together.
    static func bounce(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        // Pivot at center once, so the scale reads as a bounce, not a corner skew.
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        }

        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 0.74, 1.18, 0.94, 1.0]
        bounce.keyTimes = [0, 0.28, 0.6, 0.82, 1.0]
        bounce.duration = 0.36
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "captureBounce")
    }
}

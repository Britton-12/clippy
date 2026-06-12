import AppKit

// The menu bar icon: a custom paperclip drawn to evoke Clippy — an open gem-clip
// wire with two eyes and expressive eyebrows. Rendered through a resolution-
// independent drawing handler so it stays crisp at any backing scale (on Retina
// the menu bar draws it at 2x, where the eyes and brows read clearly). It is a
// template image, so the system tints it for the light/dark menu bar; the eyes
// sit in the clip's open area as solid ink dots rather than holes in the wire.
enum StatusBarIcon {
    private static let canvas = NSSize(width: 18, height: 18)

    /// The Clippy paperclip as a template image. `paused` closes the eyes into
    /// sleepy lids to signal capture is paused.
    static func image(paused: Bool = false) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { destRect in
            // Use destRect rather than the fixed canvas constant: on Retina the
            // system asks for a 2x backing rect (e.g. 36x36 for an 18pt image)
            // and we must fill it entirely, otherwise the top half is blank.
            draw(in: destRect.size, paused: paused)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Drawing

    /// Geometry verified at large scale before porting; `s` maps the 18pt design
    /// grid onto the actual canvas so it is resolution independent.
    private static func draw(in size: NSSize, paused: Bool) {
        let s = size.width / 18.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        NSColor.black.set()

        // Outer loop: a tall capsule open at the top so the two wire ends show.
        let lx: CGFloat = 4.6, rx: CGFloat = 13.4
        let botC: CGFloat = 6.2, botR = (rx - lx) / 2
        let topY: CGFloat = 15.2

        let wire = NSBezierPath()
        wire.move(to: p(lx, topY))
        wire.line(to: p(lx, botC))
        wire.appendArc(withCenter: p(9, botC), radius: botR * s, startAngle: 180, endAngle: 360)
        wire.line(to: p(rx, topY))

        // Inner tongue: the gem-clip's inner bend, a centre wire with a small curl.
        let ix: CGFloat = 9.0
        let tongue = NSBezierPath()
        tongue.move(to: p(ix - 1.6, 13.0))
        tongue.line(to: p(ix - 1.6, 9.0))
        tongue.appendArc(withCenter: p(ix, 9.0), radius: 1.6 * s, startAngle: 180, endAngle: 360)
        tongue.line(to: p(ix + 1.6, 12.2))
        wire.append(tongue)

        wire.lineWidth = 1.5 * s
        wire.lineCapStyle = .round
        wire.lineJoinStyle = .round
        wire.stroke()

        // Eyes (and brows) sit in the clip's open head area.
        let eyeY: CGFloat = 13.6
        for cx in [7.4 as CGFloat, 10.6] {
            if paused {
                NSBezierPath(roundedRect: NSRect(x: (cx - 0.95) * s, y: (eyeY - 0.28) * s,
                                                 width: 1.9 * s, height: 0.56 * s),
                             xRadius: 0.28 * s, yRadius: 0.28 * s).fill()
            } else {
                let r: CGFloat = 0.95
                NSBezierPath(ovalIn: NSRect(x: (cx - r) * s, y: (eyeY - r) * s,
                                            width: r * 2 * s, height: r * 2 * s)).fill()
                let brow = NSBezierPath()
                brow.move(to: p(cx - 1.0, eyeY + 1.5))
                brow.line(to: p(cx + 0.9, eyeY + 2.1))
                brow.lineWidth = 0.7 * s
                brow.lineCapStyle = .round
                brow.stroke()
            }
        }
    }

    /// Squash-and-stretch hop on the status button, pivoting at its center.
    /// Called in sync with the capture sound so icon and sound fire together.
    static func bounce(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        }

        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 0.78, 1.16, 0.95, 1.0]
        bounce.keyTimes = [0, 0.28, 0.6, 0.82, 1.0]
        bounce.duration = 0.34
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "captureBounce")
    }
}

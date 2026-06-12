import AppKit

// The menu bar icon: the system "clipboard" SF Symbol, rendered ~10% larger
// than the macOS default so it reads clearly, and able to bounce on each
// capture in sync with the sound.
enum StatusBarIcon {
    // The stock menu bar symbol sits around 14.5pt; 16pt is ~10% larger.
    private static let pointSize: CGFloat = 16

    /// The clipboard glyph as a template image (auto-tinted by the menu bar).
    /// `paused` swaps to the filled variant to signal capture is paused.
    static func image(paused: Bool = false) -> NSImage {
        let symbol = paused ? "clipboard.fill" : "clipboard"
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clippy")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
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

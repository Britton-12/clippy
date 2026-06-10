import AppKit

// Menu-bar-only app: no Dock icon, no main window. The .accessory policy is
// what LSUIElement would do in a bundled build, set here so the bare
// executable behaves the same during development.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

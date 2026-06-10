import AppKit
import SwiftUI

/// The clip editor lives in a normal activating window (unlike the panel):
/// editing is a deliberate action where stealing focus is fine.
final class EditorWindowController {
    private var window: NSWindow?

    func open(clip: Clip, onSave: @escaping (String) -> Void) {
        let editor = ClipEditorView(
            initialText: clip.contentText,
            onSave: { [weak self] text in
                onSave(text)
                self?.close()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Clip"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }
}

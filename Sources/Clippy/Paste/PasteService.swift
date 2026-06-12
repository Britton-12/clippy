import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Writes a clip to the pasteboard and simulates Cmd-V into the frontmost
/// app. The keystroke needs Accessibility permission; without it the clip
/// still lands on the clipboard for a manual paste.
final class PasteService {
    private let monitor: ClipboardMonitor
    private let settings = AppSettings.shared

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    // MARK: - Public API

    /// Writes `clip` to the pasteboard and sends Cmd+V into the frontmost app.
    func paste(_ clip: Clip, asPlainText: Bool) {
        // With move-to-top off (the default), our own pasteboard write is
        // invisible to the monitor so history order stays stable.
        if !settings.movePastedItemToTop {
            monitor.ignoreNextChange()
        }
        writeToPasteboard(clip, asPlainText: asPlainText)
        // Small delay so the panel is gone and the previous app is key again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendPasteKeystroke()
        }
    }

    /// Writes `clip` to the pasteboard without sending Cmd+V. Used by the
    /// copy-only click mode and the keystroke engine (which types the text
    /// directly instead of pasting).
    func copy(_ clip: Clip, asPlainText: Bool) {
        if !settings.movePastedItemToTop {
            monitor.ignoreNextChange()
        }
        writeToPasteboard(clip, asPlainText: asPlainText)
    }

    // MARK: - Private helpers

    private func writeToPasteboard(_ clip: Clip, asPlainText: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch clip.contentKind {
        case .image:
            if let filename = clip.mediaFilename,
               let data = try? Data(contentsOf: ClipDatabase.shared.media.url(for: filename)) {
                pasteboard.setData(data, forType: .png)
                // TIFF alongside PNG: some AppKit apps only read TIFF.
                if let rep = NSBitmapImageRep(data: data),
                   let tiff = rep.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            }
        case .text:
            if !asPlainText {
                if let rtf = clip.contentRTF {
                    pasteboard.setData(rtf, forType: .rtf)
                }
                if let html = clip.contentHTML {
                    pasteboard.setData(html, forType: .html)
                }
            }
            // Plain text is set from the stored raw String, never round-tripped
            // through attributed strings, so it comes back byte for byte.
            pasteboard.setString(clip.contentText, forType: .string)
        }
    }

    private static func sendPasteKeystroke() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

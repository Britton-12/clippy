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

    func paste(_ clip: Clip, asPlainText: Bool) {
        // With move-to-top off (the default), our own pasteboard write is
        // invisible to the monitor so history order stays stable.
        if !settings.movePastedItemToTop {
            monitor.ignoreNextChange()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
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

        // Small delay so the panel is gone and the previous app is key again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendPasteKeystroke()
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

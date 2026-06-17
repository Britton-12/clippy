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

    /// Pastes several clips one after another as discrete Cmd-V events, in order.
    /// Each lands at the current cursor; Clippy cannot move the target's cursor
    /// between events, so consecutive pastes concatenate where the caret is.
    func pasteSequence(_ clips: [Clip], asPlainText: Bool) {
        guard !clips.isEmpty else { return }
        let step = 0.15
        for (i, clip) in clips.enumerated() {
            let delay = 0.12 + Double(i) * step
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if !self.settings.movePastedItemToTop { self.monitor.ignoreNextChange() }
                self.writeToPasteboard(clip, asPlainText: asPlainText)
                Self.sendPasteKeystroke()
            }
        }
    }

    /// Joins the text of several clips with `separator` and pastes once.
    /// Image clips are skipped (text-only join).
    func pasteCombined(_ clips: [Clip], separator: String = "\n", asPlainText: Bool) {
        let text = clips.filter { $0.contentKind == .text }
            .map { $0.contentText }
            .joined(separator: separator)
        guard !text.isEmpty else { return }
        if !settings.movePastedItemToTop { monitor.ignoreNextChange() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendPasteKeystroke()
        }
    }

    /// Pastes a file clip, optionally using Cmd+Option+V (Finder "Move Item Here")
    /// instead of Cmd+V. Has no effect when the clip is not a file kind.
    func pasteFile(_ clip: Clip, move: Bool) {
        guard clip.contentKind == .file else { return }
        if !settings.movePastedItemToTop {
            monitor.ignoreNextChange()
        }
        writeToPasteboard(clip, asPlainText: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            move ? Self.sendMoveKeystroke() : Self.sendPasteKeystroke()
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
        case .file:
            if let fileURL = resolvedFileURL(for: clip) {
                (fileURL as NSURL).write(to: pasteboard)
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

    /// Resolves the best available URL for a file clip.
    /// Prefers the original path when the file still exists; falls back to writing
    /// the stored bytes to a temp file named after the original display name.
    private func resolvedFileURL(for clip: Clip) -> URL? {
        // Prefer the live original.
        if let path = clip.filePath {
            let original = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: original.path) {
                return original
            }
        }

        // Fall back to the stored copy: write bytes to a per-session temp file.
        guard let mediaFilename = clip.mediaFilename else { return nil }
        let storedURL = ClipDatabase.shared.media.url(for: mediaFilename)
        guard FileManager.default.fileExists(atPath: storedURL.path),
              let data = try? Data(contentsOf: storedURL, options: .mappedIfSafe)
        else { return nil }

        // Use the clip's display name (original filename) as the temp filename
        // so the receiving app sees a meaningful name rather than the hash.
        let displayName = clip.filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                       ?? clip.contentText
        let safeName = displayName.isEmpty ? mediaFilename : displayName
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(safeName)
        do {
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            return nil
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

    /// Sends Cmd+Option+V: Finder's "Move Item Here" shortcut.
    private static func sendMoveKeystroke() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = [.maskCommand, .maskAlternate]
        keyUp.flags = [.maskCommand, .maskAlternate]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

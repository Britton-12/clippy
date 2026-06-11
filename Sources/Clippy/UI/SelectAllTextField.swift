import AppKit
import SwiftUI

// SwiftUI's TextField cannot focus-and-select-all on appear, and styling its
// background for contrast is awkward. This AppKit-backed field does both: it
// becomes first responder and selects its whole contents the moment it appears,
// so choosing "Rename" drops the cursor in with the current title highlighted,
// ready to overtype. It is self-contained: commit/cancel report the field's own
// value, so there is no binding-timing race with the initial selection.
struct SelectAllTextField: NSViewRepresentable {
    let initialText: String
    var font: NSFont
    var textColor: NSColor
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusSelectTextField {
        let field = FocusSelectTextField(string: initialText)
        field.font = font
        field.textColor = textColor
        field.delegate = context.coordinator
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false   // the SwiftUI background provides contrast
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: FocusSelectTextField, context: Context) {
        // Do not overwrite stringValue here: that would clobber the user's edits.
        field.font = font
        field.textColor = textColor
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SelectAllTextField
        /// True once Return or Esc handled the edit, so the end-editing
        /// notification that follows does not commit a second time.
        private var resolved = false

        init(_ parent: SelectAllTextField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                resolved = true
                parent.onCommit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                resolved = true
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        // Clicking elsewhere ends editing without Return: commit what is there.
        func controlTextDidEndEditing(_ note: Notification) {
            guard !resolved, let field = note.object as? NSTextField else { return }
            resolved = true
            parent.onCommit(field.stringValue)
        }
    }
}

/// NSTextField that selects its whole contents the first time it gains focus.
final class FocusSelectTextField: NSTextField {
    private var didInitialSelect = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, !didInitialSelect {
            didInitialSelect = true
            currentEditor()?.selectAll(nil)
        }
        return became
    }
}

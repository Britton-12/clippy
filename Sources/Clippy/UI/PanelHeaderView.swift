import SwiftUI
import AppKit

/// An AppKit view that lets the user drag the borderless panel by this region
/// only. With `isMovableByWindowBackground` off on the panel, AppKit moves the
/// window only from views that return true here, so this is the sole drag area.
private final class DragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The panel's title bar: paperclip mark + "Clippy" wordmark on the left,
/// pin / settings / close controls on the right. The whole strip is draggable
/// except for the buttons.
struct PanelHeaderView: View {
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    private var tokens: ThemeTokens { AppSettings.shared.theme }
    private let settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusBarIcon.image())
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(tokens.accent)
            Text("Clippy")
                .font(PanelTypography.title(settings))
                .foregroundStyle(tokens.textPrimary)
            Spacer(minLength: 0)
            headerButton(systemName: isPinned ? "pin.fill" : "pin",
                         help: isPinned ? "Unpin panel" : "Pin panel",
                         action: onTogglePin)
            headerButton(systemName: "gearshape",
                         help: "Settings", action: onOpenSettings)
            headerButton(systemName: "xmark",
                         help: "Close", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(WindowDragHandle())
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }

    private func headerButton(systemName: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

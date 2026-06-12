import SwiftUI

/// One clipboard item rendered as a card: colored edge stripe (per-app or
/// per-kind tint), source app icon, content-type badge, preview text or image
/// thumbnail, and hover-revealed quick actions. Selection draws an accent ring.
struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    let isPinned: Bool
    /// Colors of the categories this clip belongs to (first three shown as dots).
    let categoryColors: [Color]
    /// First category the clip belongs to (by sortOrder/createdAt). When set,
    /// its icon replaces the app icon and its color overrides the stripe color.
    let pinnedCategory: Category?

    let onPaste: () -> Void
    let onPastePlain: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// Called when the user commits a rename. Receives nil to clear a custom
    /// title and revert to the source app name.
    let onRename: (String?) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var tokens: ThemeTokens { settings.theme }
    /// Whether the title field is in inline-edit mode. Driven by the parent via
    /// isRenamingBinding so context-menu "Rename..." can trigger it externally.
    @Binding var isRenaming: Bool

    /// Convenience init for callers that do not need external rename control.
    init(
        clip: Clip,
        isSelected: Bool,
        isPinned: Bool,
        categoryColors: [Color],
        pinnedCategory: Category?,
        isRenaming: Binding<Bool> = .constant(false),
        onPaste: @escaping () -> Void,
        onPastePlain: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void
    ) {
        self.clip = clip
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.categoryColors = categoryColors
        self.pinnedCategory = pinnedCategory
        self._isRenaming = isRenaming
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onEdit = onEdit
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onRename = onRename
    }

    private var kind: ClipKind { clip.kind }
    private var isImage: Bool { clip.contentKind == .image }

    private var cardColor: Color {
        // Pinned cards take the category color regardless of the global setting.
        if let category = pinnedCategory {
            return Color(hexString: category.colorHex)
        }
        switch settings.cardColorMode {
        case .byApp:
            return AppIconProvider.shared.dominantColor(forBundleID: clip.sourceAppBundleID) ?? kind.tint
        case .byKind:
            return kind.tint
        case .accent:
            return settings.accentColor
        case .neutral:
            return Color(nsColor: .systemGray)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Color identity stripe; hidden in plain style (no chrome at all).
            if settings.cardStyle != .plain {
                Rectangle()
                    .fill(cardColor)
                    .frame(width: 4)
            }

            VStack(alignment: .leading, spacing: 5) {
                headerRow
                if isImage {
                    imagePreview
                } else {
                    Text(clip.previewText)
                        .font(PanelTypography.body(settings))
                        .lineLimit(3)
                        .foregroundStyle(tokens.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .colorValue(let swatch) = kind {
                    swatchRow(swatch)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: isSelected ? 2 : 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(kind.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilitySummary: String {
        let content = isImage ? "Image" : clip.previewText
        return "\(clip.displayTitle), \(kind.label), \(content)\(isPinned ? ", pinned" : "")"
    }

    // MARK: - Pieces

    private var headerRow: some View {
        HStack(spacing: 6) {
            leadingIcon

            if isRenaming {
                titleEditor
            } else {
                titleLabel
            }

            Spacer(minLength: 4)

            if isHovering {
                hoverActions
            } else {
                trailingMetadata
            }
        }
        .frame(height: 20)
    }

    /// Icon slot: shows the pinned category's icon when the clip is categorized,
    /// otherwise the source app icon (or a placeholder when icons are off).
    @ViewBuilder
    private var leadingIcon: some View {
        if let category = pinnedCategory {
            categoryIcon(category)
                .frame(width: 16, height: 16)
        } else if settings.showAppIcons,
                  let icon = AppIconProvider.shared.icon(forBundleID: clip.sourceAppBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 12))
                .foregroundStyle(tokens.textSecondary)
                .frame(width: 16, height: 16)
        }
    }

    /// Renders any of the three category icon kinds, matching CategorySidePane.
    @ViewBuilder
    private func categoryIcon(_ category: Category) -> some View {
        switch category.iconKind {
        case .symbol:
            Image(systemName: category.iconValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hexString: category.colorHex))
        case .emoji:
            Text(category.iconValue)
                .font(.system(size: 13))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: category.iconValue) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The title text shown in normal (non-editing) state.
    private var titleLabel: some View {
        Text(clip.displayTitle)
            .font(PanelTypography.title(settings))
            .foregroundStyle(settings.highContrastCardText ? tokens.textPrimary : tokens.textSecondary)
            .lineLimit(1)
            .onTapGesture(count: 2) { beginRename() }
    }

    /// Inline rename field. The background is the standard editable-field color
    /// (white in light themes, dark in dark themes), which contrasts the card
    /// face so the field reads unmistakably as a text entry. Focus and full
    /// selection happen automatically via SelectAllTextField.
    private var titleEditor: some View {
        SelectAllTextField(
            initialText: clip.userTitle ?? clip.displayTitle,
            font: PanelTypography.nsTitleFont(settings),
            textColor: NSColor(tokens.textPrimary),
            onCommit: { commitRename($0) },
            onCancel: { cancelRename() }
        )
        .frame(height: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        // Opposite-luminance fill so the field never blends into the card:
        // a dark tint on light themes, a light tint on dark themes.
        .background(renameFieldFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tokens.accent, lineWidth: 1.5)
        )
    }

    private var renameFieldFill: Color {
        tokens.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
    }

    private func beginRename() {
        isRenaming = true
    }

    private func commitRename(_ value: String) {
        isRenaming = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or unchanged-from-the-app-name, clears the custom title.
        if trimmed.isEmpty || trimmed == clip.sourceAppName {
            onRename(nil)
        } else {
            onRename(trimmed)
        }
    }

    private func cancelRename() {
        isRenaming = false
    }

    private var trailingMetadata: some View {
        HStack(spacing: 6) {
            ForEach(Array(categoryColors.prefix(3).enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Image(systemName: kind.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
            if clip.isRich {
                Image(systemName: "textformat")
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.textSecondary)
                    .help("Has rich formatting")
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.accent)
            }
            Text(clip.createdAt, format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow))
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
                .monospacedDigit()
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if !isImage {
                cardActionButton("doc.on.clipboard", help: "Paste as plain text", action: onPastePlain)
                cardActionButton("pencil", help: "Edit", action: onEdit)
            }
            cardActionButton("character.cursor.ibeam", help: "Rename", action: beginRename)
            cardActionButton(
                isPinned ? "pin.slash" : "pin",
                help: isPinned ? "Unpin" : "Pin",
                action: onTogglePin
            )
            cardActionButton("trash", help: "Delete", action: onDelete)
        }
    }

    private func cardActionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tokens.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Body re-evaluates often (hover, selection); thumbnails come from this
    /// cache instead of disk after the first load.
    private static let thumbnailCache = NSCache<NSString, NSImage>()

    private static func thumbnail(for filename: String) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: filename as NSString) {
            return cached
        }
        guard let image = NSImage(contentsOf: ClipDatabase.shared.media.url(for: filename)) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: filename as NSString)
        return image
    }

    private var imagePreview: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if let filename = clip.thumbFilename,
                   let nsImage = Self.thumbnail(for: filename) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 72, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(width: 72, height: 48)
                }
            }
            if let width = clip.pixelWidth, let height = clip.pixelHeight {
                Text("\(width)\u{00D7}\(height) PNG")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private func swatchRow(_ swatch: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(swatch)
                .frame(width: 38, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tokens.cardBorder, lineWidth: 1)
                )
            Text(clip.contentText)
                .font(PanelTypography.micro(settings))
                .foregroundStyle(tokens.textSecondary)
                .lineLimit(1)
        }
    }

    /// Tint fraction as a 0-1 Double from the 0-20 integer setting.
    private var tintFraction: Double {
        Double(settings.cardTintStrength) / 100.0
    }

    private var cardBorderColor: Color {
        if isSelected { return tokens.accent }
        switch settings.cardStyle {
        case .filled:
            return tokens.cardBorder
        case .bordered:
            // Bordered: use the identity color as the border so cards are visually
            // distinct even without a filled background.
            return cardColor.opacity(0.6)
        case .plain:
            return .clear
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch settings.cardStyle {
        case .filled:
            ZStack {
                // Opaque themed card face: always readable, never washed out.
                tokens.cardSurface
                // Identity tint from the user-controlled strength setting.
                LinearGradient(
                    colors: [cardColor.opacity(tintFraction * (isHovering ? 2 : 1)), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                if isHovering {
                    tokens.textPrimary.opacity(0.05)
                }
            }
        case .bordered:
            ZStack {
                Color.clear
                if isHovering {
                    tokens.textPrimary.opacity(0.05)
                }
            }
        case .plain:
            Color.clear
                .overlay(isHovering ? tokens.textPrimary.opacity(0.06) : Color.clear)
        }
    }
}

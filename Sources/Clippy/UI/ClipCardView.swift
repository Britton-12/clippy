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

    let onPaste: () -> Void
    let onPastePlain: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var kind: ClipKind { clip.kind }
    private var isImage: Bool { clip.contentKind == .image }

    private var cardColor: Color {
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
            // Color identity stripe.
            Rectangle()
                .fill(cardColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                headerRow
                if isImage {
                    imagePreview
                } else {
                    Text(clip.previewText)
                        .font(.system(size: 12.5))
                        .lineLimit(3)
                        .foregroundStyle(.primary)
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
                .strokeBorder(
                    isSelected ? settings.accentColor : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: isSelected ? 2 : 1
                )
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
        let source = clip.sourceAppName ?? "Unknown app"
        let content = isImage ? "Image" : clip.previewText
        return "\(source), \(kind.label), \(content)\(isPinned ? ", pinned" : "")"
    }

    // MARK: - Pieces

    private var headerRow: some View {
        HStack(spacing: 6) {
            if settings.showAppIcons, let icon = AppIconProvider.shared.icon(forBundleID: clip.sourceAppBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            Text(clip.sourceAppName ?? "Unknown app")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovering {
                hoverActions
            } else {
                trailingMetadata
            }
        }
        .frame(height: 20)
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
                    .foregroundStyle(.secondary)
                    .help("Has rich formatting")
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(settings.accentColor)
            }
            Text(clip.createdAt, format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if !isImage {
                cardActionButton("doc.on.clipboard", help: "Paste as plain text", action: onPastePlain)
                cardActionButton("pencil", help: "Edit", action: onEdit)
            }
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
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private var imagePreview: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if let filename = clip.thumbFilename,
                   let nsImage = NSImage(contentsOf: ClipDatabase.shared.media.url(for: filename)) {
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
                Text("\(width)x\(height) PNG")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            Text("Color value")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cardBackground: some View {
        ZStack {
            // Mostly opaque backing keeps text contrast safe on glass materials.
            Color(nsColor: .controlBackgroundColor).opacity(0.78)
            // Whisper of the identity color so cards differ beyond the stripe.
            LinearGradient(
                colors: [cardColor.opacity(isHovering ? 0.16 : 0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            if isHovering {
                Color.primary.opacity(0.04)
            }
        }
    }
}

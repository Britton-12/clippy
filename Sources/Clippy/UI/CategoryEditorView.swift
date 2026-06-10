import SwiftUI

/// Popover for creating or editing a category: name, color, and an icon
/// chosen from curated SF Symbols, an emoji grid, or app logos already seen
/// in the user's history.
struct CategoryEditorView: View {
    /// nil means "create new".
    let category: Category?
    /// Bundle IDs with icons available, for the App logos tab.
    let knownBundleIDs: [String]
    let onSave: (_ name: String, _ colorHex: String, _ iconKind: CategoryIconKind, _ iconValue: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var iconKind: CategoryIconKind
    @State private var iconValue: String
    @State private var iconTab: CategoryIconKind

    private static let symbols: [String] = [
        "pin.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill", "tag.fill",
        "folder.fill", "tray.full.fill", "doc.text.fill", "terminal.fill", "curlybraces",
        "chevron.left.forwardslash.chevron.right", "link", "envelope.fill", "key.fill",
        "lock.fill", "creditcard.fill", "cart.fill", "gift.fill", "book.fill",
        "graduationcap.fill", "briefcase.fill", "house.fill", "airplane", "car.fill",
        "gamecontroller.fill", "music.note", "photo.fill", "paintpalette.fill", "lightbulb.fill",
    ]

    private static let emojis: [String] = [
        "\u{1F4CC}", "\u{2B50}", "\u{2764}\u{FE0F}", "\u{1F525}", "\u{26A1}", "\u{1F3F7}",
        "\u{1F4C1}", "\u{1F5C2}", "\u{1F4C4}", "\u{1F4BB}", "\u{1F9E0}", "\u{1F517}",
        "\u{2709}\u{FE0F}", "\u{1F511}", "\u{1F512}", "\u{1F4B3}", "\u{1F6D2}", "\u{1F381}",
        "\u{1F4DA}", "\u{1F393}", "\u{1F4BC}", "\u{1F3E0}", "\u{2708}\u{FE0F}", "\u{1F697}",
        "\u{1F3AE}", "\u{1F3B5}", "\u{1F5BC}", "\u{1F3A8}", "\u{1F4A1}", "\u{2705}",
        "\u{1F4DD}", "\u{1F916}",
    ]

    init(
        category: Category?,
        knownBundleIDs: [String],
        onSave: @escaping (String, String, CategoryIconKind, String) -> Void
    ) {
        self.category = category
        self.knownBundleIDs = knownBundleIDs
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _colorHex = State(initialValue: category?.colorHex ?? CategoryPalette.hexes[0])
        _iconKind = State(initialValue: category?.iconKind ?? .symbol)
        _iconValue = State(initialValue: category?.iconValue ?? "pin.fill")
        _iconTab = State(initialValue: category?.iconKind ?? .symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(CategoryPalette.hexes, id: \.self) { hex in
                        colorSwatch(hex)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Icon", selection: $iconTab) {
                    Text("Symbols").tag(CategoryIconKind.symbol)
                    Text("Emoji").tag(CategoryIconKind.emoji)
                    Text("Apps").tag(CategoryIconKind.appLogo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                iconGrid
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(category == nil ? "Create" : "Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespaces),
                        colorHex,
                        iconKind,
                        iconValue
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func colorSwatch(_ hex: String) -> some View {
        let isSelected = colorHex == hex
        return Button {
            colorHex = hex
        } label: {
            Circle()
                .fill(Color(hexString: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
    }

    @ViewBuilder
    private var iconGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 30), spacing: 4)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                switch iconTab {
                case .symbol:
                    ForEach(Self.symbols, id: \.self) { symbol in
                        iconCell(isSelected: iconKind == .symbol && iconValue == symbol) {
                            iconKind = .symbol
                            iconValue = symbol
                        } content: {
                            Image(systemName: symbol).font(.system(size: 14))
                        }
                        .accessibilityLabel(symbol)
                    }
                case .emoji:
                    ForEach(Self.emojis, id: \.self) { emoji in
                        iconCell(isSelected: iconKind == .emoji && iconValue == emoji) {
                            iconKind = .emoji
                            iconValue = emoji
                        } content: {
                            Text(emoji).font(.system(size: 15))
                        }
                        .accessibilityLabel(emoji)
                    }
                case .appLogo:
                    ForEach(knownBundleIDs, id: \.self) { bundleID in
                        iconCell(isSelected: iconKind == .appLogo && iconValue == bundleID) {
                            iconKind = .appLogo
                            iconValue = bundleID
                        } content: {
                            if let icon = AppIconProvider.shared.icon(forBundleID: bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 14))
                            }
                        }
                        .accessibilityLabel(bundleID)
                    }
                }
            }
        }
        .frame(height: 110)
    }

    private func iconCell<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 30, height: 28)
                .background(
                    isSelected ? AnyShapeStyle(Color(hexString: colorHex).opacity(0.25)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }
}

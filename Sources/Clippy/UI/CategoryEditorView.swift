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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onSave(name.trimmingCharacters(in: .whitespaces), colorHex, iconKind, iconValue)
                    dismiss()
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(CategoryPalette.hexes.enumerated()), id: \.element) { index, hex in
                        colorSwatch(hex, index: index + 1)
                    }
                }
            }

            IconPickerView(
                iconKind: $iconKind,
                iconValue: $iconValue,
                knownBundleIDs: knownBundleIDs,
                accentHex: colorHex
            )

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

    private func colorSwatch(_ hex: String, index: Int) -> some View {
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
        .accessibilityLabel("Color \(index)")
    }

}

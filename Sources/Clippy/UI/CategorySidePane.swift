import SwiftUI

/// Right-hand quarter of the panel: a History home row, one row per category,
/// and a New Category row. Category rows accept drops of clip IDs and own the
/// category context menu and editor popover.
struct CategorySidePane: View {
    @ObservedObject var store: ClipStore
    @Binding var selection: PanelSelection

    @ObservedObject private var settings = AppSettings.shared
    @State private var editingCategory: Category?
    @State private var isCreating = false
    /// Category currently being dragged, so a drop target can compute the move.
    @State private var draggingCategoryID: Int64?

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            historyRow
            Rectangle()
                .fill(tokens.cardBorder.opacity(0.6))
                .frame(height: 1)
                .padding(.vertical, 4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.categories) { category in
                        categoryRow(category)
                    }
                }
            }
            Spacer(minLength: 0)
            newCategoryRow
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tokens.sidebar.opacity(settings.panelOpacity))
        .accessibilityLabel("Categories")
    }

    // MARK: - Rows

    private var historyRow: some View {
        sidePaneRow(
            isSelected: selection == .history,
            tint: settings.accentColor,
            icon: { Image(systemName: "clock").font(.system(size: 12, weight: .semibold)) },
            title: "History",
            count: nil,
            help: "All history (\u{2318}1)"
        ) {
            selection = .history
        }
        .accessibilityLabel("History")
    }

    private func categoryRow(_ category: Category) -> some View {
        let categoryID = category.id ?? -1
        let isSelected = selection == .category(categoryID)
        let tint = Color(hexString: category.colorHex)
        return sidePaneRow(
            isSelected: isSelected,
            tint: tint,
            icon: { categoryIcon(category) },
            title: category.name,
            count: store.clipCount(inCategory: categoryID),
            help: category.name
        ) {
            selection = isSelected ? .history : .category(categoryID)
        }
        .contextMenu {
            Button("Edit...") { editingCategory = category }
            Divider()
            // Every category, including the starter "Pinned", can be deleted.
            // Its clips simply lose that membership (and unpin if it was their
            // only category).
            Button("Delete", role: .destructive) {
                if selection == .category(categoryID) { selection = .history }
                store.deleteCategory(category)
            }
        }
        .popover(
            isPresented: Binding(
                get: { editingCategory?.id == category.id },
                set: { if !$0 { editingCategory = nil } }
            )
        ) {
            CategoryEditorView(category: category, knownBundleIDs: store.knownBundleIDs) { name, colorHex, iconKind, iconValue in
                var updated = category
                updated.name = name
                updated.colorHex = colorHex
                updated.iconKind = iconKind
                updated.iconValue = iconValue
                store.updateCategory(updated)
            }
        }
        // Drag a category onto another to reorder; drag a clip card onto a
        // category to file it there. The payload prefix disambiguates the two.
        .draggable("cat:\(categoryID)") {
            categoryIcon(category)
                .foregroundStyle(tint)
                .padding(6)
                .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            if payload.hasPrefix("cat:") {
                guard let draggedID = Int64(payload.dropFirst(4)), draggedID != categoryID else { return false }
                store.moveCategory(id: draggedID, beforeCategoryID: categoryID)
                return true
            }
            guard let clipID = Int64(payload) else { return false }
            store.addClip(id: clipID, toCategory: categoryID)
            return true
        }
        .accessibilityLabel("\(category.name), \(store.clipCount(inCategory: categoryID)) clips")
    }

    private var newCategoryRow: some View {
        sidePaneRow(
            isSelected: false,
            tint: .secondary,
            icon: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) },
            title: "New Category",
            count: nil,
            help: "Create a category"
        ) {
            isCreating = true
        }
        .popover(isPresented: $isCreating) {
            CategoryEditorView(category: nil, knownBundleIDs: store.knownBundleIDs) { name, colorHex, iconKind, iconValue in
                store.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
            }
        }
        .accessibilityLabel("New Category")
    }

    // MARK: - Pieces

    @ViewBuilder
    private func categoryIcon(_ category: Category) -> some View {
        switch category.iconKind {
        case .symbol:
            Image(systemName: category.iconValue)
                .font(.system(size: 12, weight: .semibold))
        case .emoji:
            Text(category.iconValue)
                .font(.system(size: 13))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: category.iconValue) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12))
            }
        }
    }

    private func sidePaneRow<Icon: View>(
        isSelected: Bool,
        tint: Color,
        @ViewBuilder icon: () -> Icon,
        title: String,
        count: Int?,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon()
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(PanelTypography.metadata(settings).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let count {
                    Text("\(count)")
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

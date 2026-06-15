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
    /// Category row the cursor is hovering over during a category reorder drag.
    @State private var draggingOverCategoryID: Int64?

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
                        let categoryID = category.id ?? -1
                        categoryRow(category)
                            // "cat" kind tag distinguishes category tokens from
                            // clip-reorder tokens ("reorder:clip:<id>"), which
                            // share the same "reorder:" prefix. The tag lets the
                            // sidebar clip-filing drop branch by TYPE alone,
                            // eliminating the id-vs-category value check that
                            // silently failed when clip.id == category.id.
                            .reorderDraggable(id: categoryID, kind: "cat")
                            .reorderDropDestination(
                                id: categoryID,
                                kind: "cat",
                                draggingOver: $draggingOverCategoryID
                            ) { draggedID, targetID in
                                store.moveCategory(id: draggedID, beforeCategoryID: targetID)
                            }
                    }
                    if settings.onePasswordEnabled {
                        onePasswordRow
                    }
                    scriptsRow
                    if settings.aiEnabled {
                        assistantRow
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
        // Accept clip drops for filing. Category-to-category reorder is handled
        // by .reorderDraggable/.reorderDropDestination at the ForEach level.
        //
        // Payload shapes accepted here — routing is by TAG only, never by
        // comparing the integer value to the category list:
        //
        //   "clip:<n>"            clip from the History pane
        //                         (CategoryReorderModifier, no active category)
        //
        //   "reorder:clip:<n>"    clip from a category pane
        //                         (CategoryReorderModifier with kind "clip")
        //
        // Category-reorder tokens ("reorder:cat:<n>") are NOT listed here and
        // fall through to return false, allowing the outer reorderDropDestination
        // (kind "cat") to handle them. This works even when clip.id == category.id
        // because routing is determined by the kind tag, not the integer value.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }

            if payload.hasPrefix("clip:") {
                // History-pane clip filing: "clip:<n>"
                guard let clipID = Int64(payload.dropFirst(5)) else { return false }
                store.addClip(id: clipID, toCategory: categoryID)
                return true
            }

            if payload.hasPrefix("reorder:clip:") {
                // Category-pane clip filing: "reorder:clip:<n>"
                guard let clipID = Int64(payload.dropFirst(13)) else { return false }
                store.addClip(id: clipID, toCategory: categoryID)
                return true
            }

            // "reorder:cat:<n>" and any other payload: not our responsibility.
            return false
        }
        .accessibilityLabel("\(category.name), \(store.clipCount(inCategory: categoryID)) clips")
    }

    private var onePasswordRow: some View {
        sidePaneRow(
            isSelected: selection == .onePassword,
            tint: tokens.accent,
            icon: { Image(systemName: "key.fill").font(.system(size: 12, weight: .semibold)) },
            title: "1Password",
            count: nil,
            help: "Secrets shared to Clippy"
        ) {
            selection = selection == .onePassword ? .history : .onePassword
        }
        .accessibilityLabel("1Password secrets")
    }

    private var scriptsRow: some View {
        sidePaneRow(
            isSelected: selection == .scripts,
            tint: Color(nsColor: .systemGreen),
            icon: { Image(systemName: "terminal.fill").font(.system(size: 12, weight: .semibold)) },
            title: "Scripts",
            count: nil,
            help: "Run saved scripts"
        ) {
            selection = selection == .scripts ? .history : .scripts
        }
        .accessibilityLabel("Scripts")
    }

    private var assistantRow: some View {
        sidePaneRow(
            isSelected: selection == .assistant,
            tint: Color(nsColor: .systemPurple),
            icon: { Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)) },
            title: "Assistant",
            count: nil,
            help: "AI Assistant chat"
        ) {
            selection = selection == .assistant ? .history : .assistant
        }
        .accessibilityLabel("AI Assistant")
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

import SwiftUI

/// Right-hand quarter of the panel: a History home row, one row per category,
/// and a New Category row. Category rows accept drops of clip IDs and own the
/// category context menu and editor popover.
struct CategorySidePane: View {
    @ObservedObject var store: ClipStore
    @Binding var selection: PanelSelection

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingCategory: Category?
    @State private var isCreating = false
    /// Category row the cursor is currently hovering over during ANY drop drag
    /// (category reorder or clip filing). A single `.dropDestination(for:
    /// String.self)` accepts every string, and its isTargeted callback does not
    /// expose the dragged payload, so the hover indicator cannot branch on token
    /// type without the payload. One neutral row highlight covers both cases;
    /// the drop closure resolves the concrete action via routeCategoryRowDrop.
    /// The insertion-line-vs-highlight split the old kind-filtered destination
    /// gave for free is not reproducible on a single all-strings destination, so
    /// a correct highlight beats a payload-guess that would be wrong half the time.
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
                            // share the same "reorder:" prefix. categoryRow owns
                            // the single drop destination that routes by tag.
                            .reorderDraggable(id: categoryID, kind: "cat")
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
        // ONE drop destination per category row. SwiftUI drop destinations do
        // not cascade: a destination that returns false fails the drop, it does
        // not fall through to a sibling destination. So this single surface must
        // handle all three token shapes a category row can receive, routing by
        // PREFIX only (never by comparing the integer id to the category list,
        // which silently misfired when a clip id equalled a category id):
        //
        //   "reorder:cat:<n>"   another category row  -> reorder this category
        //   "clip:<n>"          clip from History     -> file into this category
        //   "reorder:clip:<n>"  clip from a category  -> file into this category
        //
        // routeCategoryRowDrop (pure, unit-tested) decides which action applies.
        //
        // A neutral highlight marks the hovered row for any drag-in-progress.
        .background(
            draggingOverCategoryID == categoryID
                ? AnyShapeStyle(tint.opacity(0.22))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                   value: draggingOverCategoryID)
        .dropDestination(for: String.self) { items, _ in
            draggingOverCategoryID = nil
            guard let payload = items.first else { return false }
            switch routeCategoryRowDrop(payload) {
            case .reorderCategory(let draggedID):
                guard draggedID != categoryID else { return false }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    store.moveCategory(id: draggedID, beforeCategoryID: categoryID)
                }
                return true
            case .fileClip(let clipID):
                store.fileClip(id: clipID, intoCategory: categoryID)
                return true
            case .ignore:
                return false
            }
        } isTargeted: { isOver in
            draggingOverCategoryID = isOver ? categoryID : nil
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
        // Plain tappable row, not a Button. A Button captures the press, so the
        // outer .reorderDraggable on category rows would never start a drag. A
        // normal-precedence .onTapGesture selects on click while leaving
        // press-and-move free to begin the reorder drag.
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
        .onTapGesture { action() }
        .help(help)
    }
}

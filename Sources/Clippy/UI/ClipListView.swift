import SwiftUI

/// Content of the popup panel: search bar, a 75/25 split between the main
/// content pane and the category side pane, and a shortcut footer. The main
/// pane slides between History and a selected category. Keyboard driven end
/// to end.
struct ClipListView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onPaste: (Clip, Bool) -> Void
    let onEdit: (Clip) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State private var selection: PanelSelection = .history
    @State private var selectedIndex = 0
    @State private var categoryCreationClip: Clip?
    /// The ID of the clip whose title is currently being edited inline.
    @State private var renamingClipID: Int64?
    @FocusState private var searchFocused: Bool

    /// Active theme token table; every color below reads from this.
    private var tokens: ThemeTokens { settings.theme }

    /// Clips shown for the current selection, in keyboard-navigation order.
    /// History is the "loose" root: once a clip is filed into any category it
    /// behaves like a file moved into a folder and no longer appears here, only
    /// inside that category's pane.
    private var visibleClips: [Clip] {
        switch selection {
        case .history:
            return store.clips.filter { !store.isPinned($0) }
        case .category(let categoryID):
            return store.clips.filter { store.categoryIDs(for: $0).contains(categoryID) }
        case .onePassword:
            return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    mainPane
                        .frame(width: max(0, geo.size.width - sidePaneWidth(geo)))
                    Divider()
                    CategorySidePane(store: store, selection: $selection)
                        .frame(width: sidePaneWidth(geo) - 1)
                }
            }
            Divider()
            footer
        }
        .background(ThemedPanelBackground(tokens: tokens, opacity: settings.panelOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        .tint(tokens.accent)
        .onChange(of: store.clips) { _, _ in selectedIndex = 0 }
        .onChange(of: selection) { _, _ in selectedIndex = 0 }
    }

    /// Side pane takes a quarter of the panel but never less than 150pt.
    private func sidePaneWidth(_ geo: GeometryProxy) -> CGFloat {
        max(150, geo.size.width * 0.25)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        ZStack {
            if selection == .history {
                paneContent
                    .transition(paneTransition(edge: .leading))
            } else {
                paneContent
                    .id(selection)
                    .transition(paneTransition(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background behind the scrolling cards; tracks the transparency slider.
        .background(tokens.scrollBackground.opacity(settings.panelOpacity))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
        .clipped()
    }

    private func paneTransition(edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }

    @ViewBuilder
    private var paneContent: some View {
        if selection == .onePassword {
            OnePasswordView()
        } else if visibleClips.isEmpty {
            emptyState
        } else {
            sectionedList
        }
    }

    // MARK: - Header

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.textSecondary)
            TextField("Search clipboard history", text: $store.query)
                .textFieldStyle(.plain)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    pasteSelected(shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onKeyPress(keys: ["e"]) { press in
                    guard press.modifiers.contains(.command),
                          let clip = selectedClip,
                          clip.contentKind == .text
                    else { return .ignored }
                    onEdit(clip)
                    return .handled
                }
                .onKeyPress(keys: ["p"]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
                    store.togglePin(clip)
                    return .handled
                }
                .onKeyPress(keys: [.delete]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
                    store.delete(clip)
                    return .handled
                }
                .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]) { press in
                    guard press.modifiers.contains(.command),
                          let digit = press.characters.first?.wholeNumberValue
                    else { return .ignored }
                    if digit == 1 {
                        selection = .history
                        return .handled
                    }
                    let index = digit - 2
                    guard store.categories.indices.contains(index),
                          let categoryID = store.categories[index].id
                    else { return .ignored }
                    selection = .category(categoryID)
                    return .handled
                }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Clippy settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
        .onAppear { searchFocused = true }
    }

    // MARK: - Sectioned list

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [(index: Int, clip: Clip)]
    }

    private var sections: [Section] {
        let rows = Array(visibleClips.enumerated()).map { (index: $0.offset, clip: $0.element) }
        // Date headers only make sense for the chronological history.
        guard settings.showSectionHeaders, selection == .history else {
            return [Section(id: "all", title: "", rows: rows)]
        }

        var grouped: [(title: String, rows: [(index: Int, clip: Clip)])] = []
        for row in rows {
            let title = sectionTitle(for: row.clip)
            if let last = grouped.indices.last, grouped[last].title == title {
                grouped[last].rows.append(row)
            } else {
                grouped.append((title: title, rows: [row]))
            }
        }
        return grouped.map { Section(id: $0.title, title: $0.title, rows: $0.rows) }
    }

    private func sectionTitle(for clip: Clip) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(clip.createdAt) { return "Today" }
        if calendar.isDateInYesterday(clip.createdAt) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), clip.createdAt > weekAgo {
            return "This Week"
        }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()), clip.createdAt > monthAgo {
            return "This Month"
        }
        return "Earlier"
    }

    private var sectionedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6, pinnedViews: []) {
                    ForEach(sections) { section in
                        if !section.title.isEmpty {
                            sectionHeader(section.title)
                        }
                        ForEach(section.rows, id: \.clip.id) { row in
                            card(for: row.clip, at: row.index)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard visibleClips.indices.contains(newIndex) else { return }
                proxy.scrollTo(visibleClips[newIndex].id, anchor: nil)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(PanelTypography.micro(settings).weight(.semibold))
                .foregroundStyle(tokens.textSecondary)
                .kerning(0.6)
            Rectangle()
                .fill(tokens.cardBorder.opacity(0.6))
                .frame(height: 1)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    private func card(for clip: Clip, at index: Int) -> some View {
        ClipCardView(
            clip: clip,
            isSelected: index == selectedIndex,
            isPinned: store.isPinned(clip),
            categoryColors: store.categories
                .filter { category in
                    guard let id = category.id else { return false }
                    return store.categoryIDs(for: clip).contains(id)
                }
                .map { Color(hexString: $0.colorHex) },
            pinnedCategory: store.firstCategory(for: clip),
            isRenaming: Binding(
                get: { renamingClipID == clip.id },
                set: { active in renamingClipID = active ? clip.id : nil }
            ),
            onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
            onPastePlain: { onPaste(clip, true) },
            onEdit: { onEdit(clip) },
            onTogglePin: { store.togglePin(clip) },
            onDelete: { store.delete(clip) },
            onRename: { store.renameClip(clip, userTitle: $0) }
        )
        .id(clip.id)
        .onTapGesture { onPaste(clip, settings.pastePlainTextByDefault) }
        .draggable(String(clip.id ?? -1))
        .contextMenu {
            Button("Paste") { onPaste(clip, false) }
            if clip.contentKind == .text {
                Button("Paste as Plain Text") { onPaste(clip, true) }
                Divider()
                Button("Edit...") { onEdit(clip) }
            }
            // "Rename..." works for all clip kinds, not just text.
            Button("Rename...") { renamingClipID = clip.id }
            Button(store.isPinned(clip) ? "Unpin" : "Pin") { store.togglePin(clip) }
            categoriesMenu(for: clip)
            Divider()
            Button("Delete", role: .destructive) { store.delete(clip) }
        }
        .popover(
            isPresented: Binding(
                get: { categoryCreationClip?.id == clip.id },
                set: { if !$0 { categoryCreationClip = nil } }
            )
        ) {
            CategoryEditorView(category: nil, knownBundleIDs: store.knownBundleIDs) { name, colorHex, iconKind, iconValue in
                // Create the category and file the clip into it in one step.
                if let created = store.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue),
                   let categoryID = created.id,
                   let clipID = clip.id {
                    store.addClip(id: clipID, toCategory: categoryID)
                }
            }
        }
    }

    private func categoriesMenu(for clip: Clip) -> some View {
        Menu("Categories") {
            ForEach(store.categories) { category in
                let categoryID = category.id ?? -1
                let isMember = store.categoryIDs(for: clip).contains(categoryID)
                Button {
                    store.setClip(clip, inCategory: categoryID, !isMember)
                } label: {
                    if isMember {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
            Divider()
            Button("New Category...") { categoryCreationClip = clip }
        }
    }

    // MARK: - Empty and footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyIcon: String {
        switch selection {
        case .history: return "clipboard"
        case .category: return "tray"
        case .onePassword: return "key.fill"
        }
    }

    private var emptyMessage: String {
        if !store.query.isEmpty {
            return "No clips match \"\(store.query)\"."
        }
        switch selection {
        case .history:
            return "Nothing here yet. Copy something and it will show up."
        case .category:
            return "No clips in this category yet. Right-click a clip and choose Categories, or drag a card onto the category."
        case .onePassword:
            return "No secrets shared to Clippy yet."
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("\u{21A9}", settings.pastePlainTextByDefault ? "paste plain" : "paste")
            keyHint("\u{21E7}\u{21A9}", settings.pastePlainTextByDefault ? "formatted" : "plain")
            keyHint("\u{2318}P", "pin")
            keyHint("\u{238B}", "close")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(PanelTypography.metadata(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tokens.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textPrimary.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }

    // MARK: - Selection and actions

    private var selectedClip: Clip? {
        visibleClips.indices.contains(selectedIndex) ? visibleClips[selectedIndex] : nil
    }

    private func moveSelection(by delta: Int) {
        guard !visibleClips.isEmpty else { return }
        selectedIndex = max(0, min(visibleClips.count - 1, selectedIndex + delta))
    }

    private func pasteSelected(shiftHeld: Bool) {
        guard let clip = selectedClip else { return }
        // Shift inverts whichever paste mode is the configured default.
        let asPlainText = settings.pastePlainTextByDefault != shiftHeld
        onPaste(clip, asPlainText)
    }
}

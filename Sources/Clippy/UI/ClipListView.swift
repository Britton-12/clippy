import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case history
    case pinned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .history: return "History"
        case .pinned: return "Pinned"
        }
    }
}

/// Content of the popup panel: search, History/Pinned tabs, date-sectioned
/// card list, hint footer. Keyboard driven end to end.
struct ClipListView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject private var settings = AppSettings.shared

    let onPaste: (Clip, Bool) -> Void
    let onEdit: (Clip) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State private var tab: PanelTab = .history
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    /// Clips shown for the current tab, in keyboard-navigation order.
    private var visibleClips: [Clip] {
        switch tab {
        case .history: return store.clips
        case .pinned: return store.clips.filter(\.isPinned)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            tabBar
            Divider()
            if visibleClips.isEmpty {
                emptyState
            } else {
                sectionedList
            }
            Divider()
            footer
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .tint(settings.accentColor)
        .onChange(of: store.clips) { _, _ in selectedIndex = 0 }
        .onChange(of: tab) { _, _ in selectedIndex = 0 }
    }

    @ViewBuilder
    private var panelBackground: some View {
        if let material = settings.panelMaterial.material {
            Rectangle().fill(material)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - Header

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    pasteSelected(shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onKeyPress(keys: ["e"]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
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
                .onKeyPress(keys: ["1"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    tab = .history
                    return .handled
                }
                .onKeyPress(keys: ["2"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    tab = .pinned
                    return .handled
                }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clippy settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onAppear { searchFocused = true }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(PanelTab.allCases) { candidate in
                tabButton(candidate)
            }
            Spacer()
            Text("\(visibleClips.count) \(visibleClips.count == 1 ? "clip" : "clips")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func tabButton(_ candidate: PanelTab) -> some View {
        let isActive = tab == candidate
        return Button {
            tab = candidate
        } label: {
            HStack(spacing: 4) {
                Image(systemName: candidate == .history ? "clock" : "pin")
                    .font(.system(size: 9, weight: .semibold))
                Text(candidate.label)
                    .font(.caption.weight(isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isActive ? AnyShapeStyle(settings.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? settings.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
            )
            .foregroundStyle(isActive ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(candidate == .history ? "All history (cmd 1)" : "Pinned items (cmd 2)")
    }

    // MARK: - Sectioned list

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [(index: Int, clip: Clip)]
    }

    private var sections: [Section] {
        let rows = Array(visibleClips.enumerated()).map { (index: $0.offset, clip: $0.element) }
        guard settings.showSectionHeaders else {
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
        if tab == .history, clip.isPinned { return "Pinned" }
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    private func card(for clip: Clip, at index: Int) -> some View {
        ClipCardView(
            clip: clip,
            isSelected: index == selectedIndex,
            onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
            onPastePlain: { onPaste(clip, true) },
            onEdit: { onEdit(clip) },
            onTogglePin: { store.togglePin(clip) },
            onDelete: { store.delete(clip) }
        )
        .id(clip.id)
        .onTapGesture { onPaste(clip, settings.pastePlainTextByDefault) }
        .contextMenu {
            Button("Paste") { onPaste(clip, false) }
            Button("Paste as Plain Text") { onPaste(clip, true) }
            Divider()
            Button("Edit...") { onEdit(clip) }
            Button(clip.isPinned ? "Unpin" : "Pin") { store.togglePin(clip) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(clip) }
        }
    }

    // MARK: - Empty and footer

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: tab == .pinned ? "pin" : "clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyMessage: String {
        if !store.query.isEmpty {
            return "No clips match \"\(store.query)\"."
        }
        switch tab {
        case .history: return "Nothing here yet. Copy something and it will show up."
        case .pinned: return "No pinned clips. Select a clip and press \u{2318}P to keep it here."
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            keyHint("\u{21A9}", settings.pastePlainTextByDefault ? "paste plain" : "paste")
            keyHint("\u{21E7}\u{21A9}", settings.pastePlainTextByDefault ? "formatted" : "plain")
            keyHint("\u{2318}E", "edit")
            keyHint("\u{2318}P", "pin")
            keyHint("\u{238B}", "close")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            Text(action)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
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

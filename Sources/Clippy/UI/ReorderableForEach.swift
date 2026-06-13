import SwiftUI

// MARK: - Drag-to-reorder view modifiers for LazyVStack lists
//
// Native .onMove requires List, which is unavailable in LazyVStack layouts.
// These two modifiers wire .draggable + .dropDestination with a subtle
// insertion-line indicator so any row in a LazyVStack can participate in
// drag-to-reorder. Each row encodes its ID as a "reorder:<id>" String token
// to avoid colliding with other drag payloads (e.g. clip-to-category drops).
//
// Usage:
//   ForEach(items) { item in
//       rowView(item)
//           .reorderDraggable(id: item.id)
//           .reorderDropDestination(id: item.id, draggingOver: $draggingOverID) {
//               draggedID, targetID in store.moveItem(draggedID, before: targetID)
//           }
//   }

private let reorderPrefix = "reorder:"

// MARK: - Draggable modifier

struct ReorderDraggableModifier<ID: CustomStringConvertible>: ViewModifier {
    let id: ID

    func body(content: Content) -> some View {
        content.draggable("\(reorderPrefix)\(id)")
    }
}

extension View {
    /// Makes this row draggable for within-list reorder. The token is prefixed
    /// with "reorder:" so drop destinations can distinguish it from other
    /// drag payloads (e.g. clip IDs dragged to a category row).
    func reorderDraggable<ID: CustomStringConvertible>(id: ID) -> some View {
        modifier(ReorderDraggableModifier(id: id))
    }
}

// MARK: - Drop destination modifier

struct ReorderDropDestinationModifier<ID: LosslessStringConvertible & Equatable>: ViewModifier {
    let id: ID
    @Binding var draggingOver: ID?
    let onMove: (ID, ID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Insertion line above the row that is being hovered over.
            .overlay(alignment: .top) {
                if draggingOver == id {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: draggingOver)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                draggingOver = nil
                guard let token = items.first,
                      token.hasPrefix(reorderPrefix) else { return false }
                let raw = String(token.dropFirst(reorderPrefix.count))
                guard let draggedID = ID(raw), draggedID != id else { return false }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    onMove(draggedID, id)
                }
                return true
            } isTargeted: { isOver in
                draggingOver = isOver ? id : nil
            }
    }
}

extension View {
    /// Accepts a reorder drop from another row carrying the same ID type.
    /// - Parameters:
    ///   - id: This row's identifier. The drop moves the dragged item before this one.
    ///   - draggingOver: Binding used for the insertion-line indicator. Share one
    ///     `@State` variable across all rows in the list.
    ///   - onMove: Called with (draggedID, targetID) when the drop lands. The
    ///     caller is responsible for mutating the data model.
    func reorderDropDestination<ID: LosslessStringConvertible & Equatable>(
        id: ID,
        draggingOver: Binding<ID?>,
        onMove: @escaping (ID, ID) -> Void
    ) -> some View {
        modifier(ReorderDropDestinationModifier(id: id, draggingOver: draggingOver, onMove: onMove))
    }
}

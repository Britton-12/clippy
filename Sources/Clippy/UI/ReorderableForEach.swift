import SwiftUI

// MARK: - Drag-to-reorder view modifiers for LazyVStack lists
//
// Native .onMove requires List, which is unavailable in LazyVStack layouts.
// These two modifiers wire .draggable + .dropDestination with a subtle
// insertion-line indicator so any row in a LazyVStack can participate in
// drag-to-reorder.
//
// Token format:
//   No kind (default):  "reorder:<id>"           -- scripts, AI-actions (unchanged)
//   With kind:          "reorder:<kind>:<id>"     -- clips use "clip", categories use "cat"
//
// The kind tag lets CategorySidePane's drop handler distinguish a clip being
// reordered inside a category pane from a category row being reordered in the
// sidebar — both previously emitted "reorder:<id>" with no way to tell apart
// by type, causing silent filing failures when clip.id == category.id.
//
// Usage (kind-tagged):
//   ForEach(items) { item in
//       rowView(item)
//           .reorderDraggable(id: item.id, kind: "cat")
//           .reorderDropDestination(id: item.id, kind: "cat", draggingOver: $draggingOverID) {
//               draggedID, targetID in store.moveItem(draggedID, before: targetID)
//           }
//   }
//
// Usage (default, no kind — existing call sites compile unchanged):
//   .reorderDraggable(id: item.id)
//   .reorderDropDestination(id: item.id, draggingOver: $draggingOverID) { ... }

private let reorderPrefix = "reorder:"

/// Builds the drag token for a given id and optional kind tag.
/// - kind == nil  ->  "reorder:<id>"
/// - kind == "cat" -> "reorder:cat:<id>"
private func reorderToken<ID: CustomStringConvertible>(id: ID, kind: String?) -> String {
    if let kind {
        return "\(reorderPrefix)\(kind):\(id)"
    }
    return "\(reorderPrefix)\(id)"
}

/// Parses a token produced by `reorderToken`, returning the raw ID string only
/// when the token matches the expected kind. Returns nil if the token does not
/// belong to this reorder surface (wrong prefix or wrong kind tag).
///
/// - token:        The string payload received by the drop destination.
/// - expectedKind: The kind this drop surface is responsible for (nil = no-kind surface).
private func parseReorderToken(_ token: String, expectedKind: String?) -> String? {
    guard token.hasPrefix(reorderPrefix) else { return nil }
    let afterPrefix = String(token.dropFirst(reorderPrefix.count))

    if let kind = expectedKind {
        // Expect "reorder:<kind>:<id>" — strip "<kind>:" and return the remainder.
        let kindMarker = "\(kind):"
        guard afterPrefix.hasPrefix(kindMarker) else { return nil }
        return String(afterPrefix.dropFirst(kindMarker.count))
    } else {
        // No kind expected. Accept "reorder:<id>" but NOT "reorder:<kind>:<id>",
        // so a no-kind surface does not accidentally absorb kind-tagged tokens.
        // A kind-tagged token contains at least one additional ":" separator before
        // the numeric id, so reject anything that still contains ":" after stripping.
        // Scripts/AI-actions use Int IDs with no ":", so they are unaffected.
        guard !afterPrefix.contains(":") else { return nil }
        return afterPrefix
    }
}

// MARK: - Draggable modifier

struct ReorderDraggableModifier<ID: CustomStringConvertible>: ViewModifier {
    let id: ID
    // nil = legacy "reorder:<id>" format (scripts, AI-actions);
    // non-nil = "reorder:<kind>:<id>" (clips, categories).
    let kind: String?

    func body(content: Content) -> some View {
        content.draggable(reorderToken(id: id, kind: kind))
    }
}

extension View {
    /// Makes this row draggable for within-list reorder.
    ///
    /// - Parameters:
    ///   - id:   This row's stable identifier.
    ///   - kind: Optional tag embedded in the token (e.g. "cat", "clip"). When
    ///     provided the token becomes "reorder:<kind>:<id>", which lets drop
    ///     destinations reject tokens from other reorder surfaces by tag alone,
    ///     without comparing the integer value to any data set.
    ///     Defaults to `nil` so existing call sites (scripts, AI-actions) are unchanged.
    func reorderDraggable<ID: CustomStringConvertible>(id: ID, kind: String? = nil) -> some View {
        modifier(ReorderDraggableModifier(id: id, kind: kind))
    }
}

// MARK: - Drop destination modifier

struct ReorderDropDestinationModifier<ID: LosslessStringConvertible & Equatable>: ViewModifier {
    let id: ID
    let kind: String?
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
                      let raw = parseReorderToken(token, expectedKind: kind),
                      let draggedID = ID(raw),
                      draggedID != id
                else { return false }
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
    /// Accepts a reorder drop from another row carrying the same ID type and kind.
    /// - Parameters:
    ///   - id:          This row's identifier. The drop moves the dragged item before this one.
    ///   - kind:        Must match the `kind` passed to `.reorderDraggable` on the source rows.
    ///     Defaults to `nil` so existing call sites (scripts, AI-actions) are unchanged.
    ///   - draggingOver: Binding used for the insertion-line indicator. Share one
    ///     `@State` variable across all rows in the list.
    ///   - onMove:      Called with (draggedID, targetID) when the drop lands. The
    ///     caller is responsible for mutating the data model.
    func reorderDropDestination<ID: LosslessStringConvertible & Equatable>(
        id: ID,
        kind: String? = nil,
        draggingOver: Binding<ID?>,
        onMove: @escaping (ID, ID) -> Void
    ) -> some View {
        modifier(ReorderDropDestinationModifier(id: id, kind: kind, draggingOver: draggingOver, onMove: onMove))
    }
}

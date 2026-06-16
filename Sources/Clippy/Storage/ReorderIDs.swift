import Foundation

// MARK: - Pure reorder primitive

/// Remove `draggedID` from `ids` and reinsert it immediately before `targetID`.
/// If `targetID` is nil or not found in the post-removal array, the dragged
/// element is appended to the end. If `draggedID` is not present at all, the
/// original array is returned unchanged.
///
/// This is intentionally side-effect-free so it can be unit-tested in isolation
/// from any database or persistence layer. Both `moveCategory` and `moveClip`
/// delegate the ordering computation here and own their own write paths.
func reorderIDs(_ ids: [Int64], draggedID: Int64, before targetID: Int64?) -> [Int64] {
    // Nothing to reorder if the dragged element is not in the list.
    guard let fromIndex = ids.firstIndex(of: draggedID) else { return ids }

    var result = ids
    result.remove(at: fromIndex)

    // Recompute insert position after the removal shifts indices.
    // If targetID is nil or has been removed (it was the dragged element itself),
    // append to the end.
    let insertIndex: Int
    if let target = targetID, let ti = result.firstIndex(of: target) {
        insertIndex = ti
    } else {
        insertIndex = result.count
    }

    result.insert(draggedID, at: insertIndex)
    return result
}

import XCTest
@testable import Clippy

final class ReorderIDsTests: XCTestCase {

    // MARK: - Basic movement

    func testDragEarlier() {
        // Move id 3 before id 1 -> [3, 1, 2, 4]
        let result = reorderIDs([1, 2, 3, 4], draggedID: 3, before: 1)
        XCTAssertEqual(result, [3, 1, 2, 4])
    }

    func testDragLater() {
        // Move id 1 before id 4 -> [2, 3, 1, 4]
        let result = reorderIDs([1, 2, 3, 4], draggedID: 1, before: 4)
        XCTAssertEqual(result, [2, 3, 1, 4])
    }

    // MARK: - Append paths

    func testNilTargetAppends() {
        // targetID nil -> dragged element goes to end
        let result = reorderIDs([1, 2, 3, 4], draggedID: 2, before: nil)
        XCTAssertEqual(result, [1, 3, 4, 2])
    }

    func testUnknownTargetAppends() {
        // targetID not in the list -> treat as append
        let result = reorderIDs([1, 2, 3, 4], draggedID: 2, before: 99)
        XCTAssertEqual(result, [1, 3, 4, 2])
    }

    // MARK: - Guard: draggedID absent

    func testAbsentDraggedIDReturnsUnchanged() {
        let input: [Int64] = [1, 2, 3]
        let result = reorderIDs(input, draggedID: 99, before: 2)
        XCTAssertEqual(result, input)
    }

    // MARK: - Permutation invariant

    func testResultIsPermutationOfInput() {
        let input: [Int64] = [10, 20, 30, 40, 50]
        let result = reorderIDs(input, draggedID: 30, before: 10)
        // Same elements, same count, no duplicates.
        XCTAssertEqual(result.count, input.count)
        XCTAssertEqual(Set(result), Set(input))
    }

    func testNoDuplicatesInResult() {
        let input: [Int64] = [1, 2, 3, 4]
        let result = reorderIDs(input, draggedID: 1, before: 3)
        XCTAssertEqual(result.count, Set(result).count)
    }

    // MARK: - Renumber invariant

    /// After a move, the caller writes `enumerated().offset` as the sortOrder
    /// for each element. This test pins the ACTUAL element order produced by
    /// reorderIDs so that incorrect output (e.g. [5, 10, 15, 20] unchanged, or
    /// [10, 5, 15, 20] wrong insertion point) would fail both assertions:
    ///   1. The dragged element (15) must appear at index 0 (immediately before 5).
    ///   2. The full result must equal the specific permutation [15, 5, 10, 20].
    /// Using enumerated().offset as a sortOrder on that array then yields 0, 1, 2, 3
    /// by construction -- which is the gap-free contract the DB callers rely on.
    func testSortOrderMappingProducesCorrectElementOrder() {
        let input: [Int64] = [5, 10, 15, 20]
        let result = reorderIDs(input, draggedID: 15, before: 5)
        // Dragged element must land immediately before its target.
        XCTAssertEqual(result.first, 15,
                       "dragged element must be at position 0 (immediately before target 5)")
        // Full ordering must match the expected permutation exactly.
        XCTAssertEqual(result, [15, 5, 10, 20],
                       "element order must be the specific permutation produced by the move")
        // Result must remain a permutation of the input (no element lost or added).
        XCTAssertEqual(Set(result), Set(input), "result must contain exactly the input elements")
    }

    /// Nil target moves the dragged element to the end. Same permutation + position
    /// assertion pattern as above, proving the append branch also produces the right
    /// concrete order (not just any valid array).
    func testSortOrderMappingNilTargetAppendsCorrectly() {
        let input: [Int64] = [5, 10, 15, 20]
        let result = reorderIDs(input, draggedID: 5, before: nil)
        XCTAssertEqual(result.last, 5,
                       "nil target must place dragged element at the last position")
        XCTAssertEqual(result, [10, 15, 20, 5],
                       "element order must be the specific permutation for an append move")
        XCTAssertEqual(Set(result), Set(input), "result must contain exactly the input elements")
    }

    // MARK: - Edge cases

    func testSingleElementNilTarget() {
        let result = reorderIDs([7], draggedID: 7, before: nil)
        XCTAssertEqual(result, [7])
    }

    func testMoveToSamePosition() {
        // Dragging an element before the element that already follows it.
        // [1, 2, 3] drag 1 before 2 -> [1, 2, 3] (no change in order)
        let result = reorderIDs([1, 2, 3], draggedID: 1, before: 2)
        XCTAssertEqual(result, [1, 2, 3])
    }
}

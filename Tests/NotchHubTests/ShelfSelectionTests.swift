import XCTest
import AppKit
@testable import NotchHub

final class ShelfSelectionTests: XCTestCase {
    @MainActor
    func testCommandTogglesAndPlainClickReplacesGroup() async {
        let ids = (0..<3).map { _ in UUID() }
        let selection = ShelfSelection()
        selection.select(ids[0], orderedIDs: ids)
        selection.select(ids[2], orderedIDs: ids, modifiers: .command)
        XCTAssertEqual(selection.ids, [ids[0], ids[2]])
        selection.select(ids[0], orderedIDs: ids, modifiers: .command)
        XCTAssertEqual(selection.ids, [ids[2]])
        selection.select(ids[1], orderedIDs: ids)
        XCTAssertEqual(selection.ids, [ids[1]])
    }

    @MainActor
    func testShiftRangeKeepsAnchorAndCommandShiftAddsRange() async {
        let ids = (0..<5).map { _ in UUID() }
        let selection = ShelfSelection()
        selection.select(ids[1], orderedIDs: ids)
        selection.select(ids[4], orderedIDs: ids, modifiers: .shift)
        XCTAssertEqual(selection.ids, Set(ids[1...4]))
        selection.select(ids[2], orderedIDs: ids, modifiers: .shift)
        XCTAssertEqual(selection.ids, Set(ids[1...2]))
        XCTAssertEqual(selection.anchor, ids[1])
        selection.select(ids[4], orderedIDs: ids, modifiers: .command)
        selection.select(ids[3], orderedIDs: ids, modifiers: [.command, .shift])
        XCTAssertEqual(selection.ids, Set(ids[1...4]))
    }

    @MainActor
    func testDraggingOrRightClickingSelectedTileKeepsWholeGroup() async {
        let ids = (0..<3).map { _ in UUID() }
        let selection = ShelfSelection()
        selection.selectAll(ids)
        selection.select(ids[1], orderedIDs: ids, preservingGroup: true)
        XCTAssertEqual(selection.ids, Set(ids))
        selection.select(ids[0], orderedIDs: ids, modifiers: .command, preservingGroup: true)
        XCTAssertEqual(selection.ids, Set(ids))
        // Обычный клик по той же карточке снова оставляет только её.
        selection.select(ids[1], orderedIDs: ids)
        XCTAssertEqual(selection.ids, [ids[1]])
        selection.select(ids[2], orderedIDs: ids, preservingGroup: true)
        XCTAssertEqual(selection.ids, [ids[2]])
    }

    @MainActor
    func testRemovingAnchorPrunesIDsAndKeepsRangeSelectionUsable() async {
        let ids = (0..<4).map { _ in UUID() }
        let selection = ShelfSelection()
        selection.select(ids[1], orderedIDs: ids)
        selection.select(ids[3], orderedIDs: ids, modifiers: .shift)
        let remaining = [ids[0], ids[2], ids[3]]
        selection.prune(to: remaining)
        XCTAssertEqual(selection.ids, [ids[2], ids[3]])
        XCTAssertEqual(selection.anchor, ids[2])
        selection.select(ids[0], orderedIDs: remaining, modifiers: .shift)
        XCTAssertEqual(selection.ids, [ids[0], ids[2]])
        selection.prune(to: [])
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertNil(selection.anchor)
        selection.select(ids[0], orderedIDs: [])
        XCTAssertTrue(selection.ids.isEmpty)
    }
}

import CoreGraphics
import XCTest
@testable import DevTabsCore

final class LayoutTreeTests: XCTestCase {
    let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let config = Config(gap: 0, barHeight: 28, accordionPadding: 30)

    private func frames(_ tree: LayoutTree, _ config: Config? = nil) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        for layout in tree.layout(in: area, config: config ?? self.config) {
            for item in layout.frames { out[item.window] = item.frame }
        }
        return out
    }

    private func insert(_ tree: LayoutTree, _ window: WindowID, focused: WindowID? = nil) {
        tree.insert(window, focused: focused, area: area, config: config)
    }

    private func stack(_ windows: [WindowID]) -> LayoutTree {
        let tree = LayoutTree()
        insert(tree, windows[0])
        tree.toggleStack(windows[0], area: area, config: config)
        for (i, w) in windows.dropFirst().enumerated() { insert(tree, w, focused: windows[i]) }
        return tree
    }

    func testFirstWindowFillsTheArea() {
        let tree = LayoutTree()
        insert(tree, 1)
        XCTAssertEqual(frames(tree)[1], area)
    }

    func testSplitFollowsTheShapeOfTheFocusedTile() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(frames(tree)[2], CGRect(x: 800, y: 0, width: 800, height: 1000))
        insert(tree, 3, focused: 2)
        XCTAssertEqual(frames(tree)[2], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(frames(tree)[3], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testGapsAroundAndBetweenTiles() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        let f = frames(tree, Config(gap: 8, barHeight: 28, accordionPadding: 30))
        XCTAssertEqual(f[1], CGRect(x: 8, y: 8, width: 788, height: 984))
        XCTAssertEqual(f[2], CGRect(x: 804, y: 8, width: 788, height: 984))
    }

    func testRemovingCollapsesTheSplit() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        XCTAssertTrue(tree.remove(2))
        XCTAssertEqual(tree.tiles.count, 1)
        XCTAssertEqual(frames(tree)[1], area)
        XCTAssertTrue(tree.remove(1))
        XCTAssertNil(tree.root)
    }

    func testNewWindowJoinsTheFocusedStack() {
        let tree = stack([1, 2])
        let tile = tree.tile(containing: 1)
        XCTAssertEqual(tile?.windows, [1, 2])
        XCTAssertEqual(tile?.activeWindow, 2)
        XCTAssertEqual(tree.tiles.count, 1)
    }

    func testMovingIntoAStackJoinsItAndShowsTheBar() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        tree.toggleStack(1, area: area, config: config)
        XCTAssertEqual(tree.move(2, .left, area: area, config: config), .joined)
        let tile = tree.tile(containing: 1)
        XCTAssertEqual(tile?.windows, [1, 2])
        XCTAssertEqual(tile?.activeWindow, 2)
        let layout = tree.layout(in: area, config: config)
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(layout[0].barRect, CGRect(x: 0, y: 0, width: 1600, height: 28))
        let content = CGRect(x: 0, y: 28, width: 1600, height: 972)
        XCTAssertEqual(frames(tree)[1], content)
        XCTAssertEqual(frames(tree)[2], content)
    }

    func testAccordionCascadesTheTabsWithTheSameWidth() {
        let tree = stack([1, 2, 3])
        tree.toggleAccordion(3)
        let f = frames(tree)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 28, width: 1540, height: 972))
        XCTAssertEqual(f[2], CGRect(x: 30, y: 28, width: 1540, height: 972))
        XCTAssertEqual(f[3], CGRect(x: 60, y: 28, width: 1540, height: 972))
    }

    func testChangingTheActiveTabDoesNotResizeAnyWindow() {
        let tree = stack([1, 2])
        tree.toggleAccordion(2)
        let before = frames(tree)
        XCTAssertEqual(tree.step(2, forward: false), 1)
        XCTAssertEqual(frames(tree), before)
        XCTAssertEqual(before[1], CGRect(x: 0, y: 28, width: 1570, height: 972))
        XCTAssertEqual(before[2], CGRect(x: 30, y: 28, width: 1570, height: 972))
    }

    func testDraggingTheLeftEdgeSetsHowMuchOfTheBackWindowShows() {
        let tree = stack([1, 2])
        tree.toggleAccordion(2)
        XCTAssertEqual(tree.adjustPeek(2, toFit: CGRect(x: 400, y: 28, width: 1200, height: 972), area: area, config: config), 400)
        let f = frames(tree)
        XCTAssertEqual(f[2], CGRect(x: 400, y: 28, width: 1200, height: 972))
        XCTAssertEqual(f[1], CGRect(x: 0, y: 28, width: 1200, height: 972))
        XCTAssertNil(tree.adjustPeek(2, toFit: CGRect(x: 400, y: 28, width: 1200, height: 972), area: area, config: config))
    }

    func testDraggingTheRightEdgeOfTheFirstTabWorksToo() {
        let tree = stack([1, 2])
        tree.toggleAccordion(2)
        tree.activate(1)
        XCTAssertEqual(tree.adjustPeek(1, toFit: CGRect(x: 0, y: 28, width: 1000, height: 972), area: area, config: config), 600)
        XCTAssertEqual(frames(tree)[2], CGRect(x: 600, y: 28, width: 1000, height: 972))
    }

    func testTheBackWindowNeverShowsMoreThanTheFrontOne() {
        let tree = stack([1, 2])
        tree.toggleAccordion(2)
        tree.adjustPeek(2, toFit: CGRect(x: 1550, y: 28, width: 50, height: 972), area: area, config: config)
        XCTAssertEqual(frames(tree)[2], CGRect(x: 800, y: 28, width: 800, height: 972))
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 28, width: 800, height: 972))
    }

    func testAMiddleTabMovesEveryStrip() {
        let tree = stack([1, 2, 3])
        tree.cycle(3, forward: false)
        tree.toggleAccordion(2)
        tree.adjustPeek(2, toFit: CGRect(x: 300, y: 28, width: 1000, height: 972), area: area, config: config)
        let f = frames(tree)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 28, width: 1000, height: 972))
        XCTAssertEqual(f[2], CGRect(x: 300, y: 28, width: 1000, height: 972))
        XCTAssertEqual(f[3], CGRect(x: 600, y: 28, width: 1000, height: 972))
    }

    func testAHiddenWindowKeepsItsPlaceAndFreesTheSpace() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        tree.setHidden(2, true)
        XCTAssertEqual(frames(tree), [1: area])
        XCTAssertTrue(tree.contains(2))
        tree.setHidden(2, false)
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(frames(tree)[2], CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testAHiddenTabComesBackToItsStack() {
        let tree = stack([1, 2, 3])
        tree.setHidden(3, true)
        let layout = tree.layout(in: area, config: config)
        XCTAssertEqual(layout.first?.frames.map(\.window), [1, 2])
        XCTAssertEqual(layout.first?.activeWindow, 2)
        tree.setHidden(3, false)
        XCTAssertEqual(tree.layout(in: area, config: config).first?.frames.map(\.window), [1, 2, 3])
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [1, 2, 3])
    }

    func testTabNavigationSkipsHiddenWindows() {
        let tree = stack([1, 2, 3])
        tree.setHidden(2, true)
        XCTAssertEqual(tree.step(3, forward: false), 1)
        XCTAssertFalse(tree.activate(2))
    }

    func testRemovingAHiddenWindowForgetsIt() {
        let tree = stack([1, 2])
        tree.setHidden(2, true)
        tree.remove(2)
        XCTAssertTrue(tree.hidden.isEmpty)
        XCTAssertEqual(tree.windows, [1])
    }

    func testAdjustPeekOnlyAppliesToTheActiveWindowOfAnAccordion() {
        let tree = stack([1, 2])
        let dragged = CGRect(x: 400, y: 28, width: 1200, height: 972)
        XCTAssertNil(tree.adjustPeek(2, toFit: dragged, area: area, config: config))
        tree.toggleAccordion(2)
        XCTAssertNil(tree.adjustPeek(1, toFit: dragged, area: area, config: config))
    }

    func testDraggingTheSharedEdgeMovesTheSplit() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        XCTAssertTrue(tree.resizeTile(1, to: CGRect(x: 0, y: 0, width: 1000, height: 1000), area: area, config: config))
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(frames(tree)[2], CGRect(x: 1000, y: 0, width: 600, height: 1000))
        XCTAssertTrue(tree.resizeTile(2, to: CGRect(x: 600, y: 0, width: 1000, height: 1000), area: area, config: config))
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 600, height: 1000))
        XCTAssertEqual(frames(tree)[2], CGRect(x: 600, y: 0, width: 1000, height: 1000))
    }

    func testDraggingAnInnerEdgeMovesTheNestedSplit() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        insert(tree, 3, focused: 2)
        XCTAssertTrue(tree.resizeTile(3, to: CGRect(x: 800, y: 300, width: 800, height: 700), area: area, config: config))
        XCTAssertEqual(frames(tree)[2], CGRect(x: 800, y: 0, width: 800, height: 300))
        XCTAssertEqual(frames(tree)[3], CGRect(x: 800, y: 300, width: 800, height: 700))
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    func testMovingAWindowOrDraggingAnOuterEdgeChangesNothing() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        XCTAssertFalse(tree.resizeTile(1, to: CGRect(x: 100, y: 50, width: 800, height: 1000), area: area, config: config))
        XCTAssertFalse(tree.resizeTile(1, to: CGRect(x: 0, y: 0, width: 800, height: 900), area: area, config: config))
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    func testDraggingTheOuterEdgeOfAnAccordionMovesTheSplit() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        tree.toggleStack(1, area: area, config: config)
        tree.move(2, .left, area: area, config: config)
        insert(tree, 3, focused: 2)
        tree.move(3, .right, area: area, config: config)
        // Stack [1, 2] a la izquierda con 2 activa (asoma 1 a la izquierda) y la ventana 3 a la derecha.
        tree.toggleAccordion(2)
        XCTAssertEqual(frames(tree)[2], CGRect(x: 30, y: 28, width: 770, height: 972))
        // El borde derecho de 2 no tiene pestañas detrás: arrastrarlo corre la división con la ventana 3.
        let dragged = CGRect(x: 30, y: 28, width: 970, height: 972)
        XCTAssertNil(tree.adjustPeek(2, toFit: dragged, area: area, config: config))
        XCTAssertTrue(tree.resizeTile(2, to: dragged, area: area, config: config))
        XCTAssertEqual(frames(tree)[2], dragged)
        XCTAssertEqual(frames(tree)[3], CGRect(x: 1000, y: 0, width: 600, height: 1000))
    }

    private func sampleTree() -> LayoutTree {
        // 1 a la izquierda; a la derecha, arriba un acordeón [2, 3] con franja ajustada y abajo la 4, oculta.
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        insert(tree, 4, focused: 2)
        tree.toggleStack(2, area: area, config: config)
        insert(tree, 3, focused: 2)
        tree.toggleAccordion(3)
        tree.adjustPeek(3, toFit: CGRect(x: 1000, y: 28, width: 600, height: 472), area: area, config: config)
        tree.adjustRatio(1, by: 0.1)
        tree.setHidden(4, true)
        return tree
    }

    func testASavedTreeComesBackTheSame() throws {
        let tree = sampleTree()
        let data = try JSONEncoder().encode(tree.snapshot)
        let restored = LayoutTree(snapshot: try JSONDecoder().decode(TreeSnapshot.self, from: data))
        XCTAssertEqual(restored.snapshot, tree.snapshot)
        XCTAssertEqual(frames(restored), frames(tree))
        XCTAssertEqual(restored.hidden, [4])
        XCTAssertEqual(restored.tile(containing: 2)?.mode, .accordion)
        XCTAssertEqual(restored.tile(containing: 2)?.activeWindow, 3)
    }

    func testRestoringDropsClosedWindowsAndEmptySpaces() {
        let restored = LayoutTree(snapshot: sampleTree().snapshot)
        restored.prune(keeping: [2, 3])
        XCTAssertEqual(restored.windows, [2, 3])
        XCTAssertEqual(restored.tiles.count, 1)
        XCTAssertTrue(restored.hidden.isEmpty)
        XCTAssertEqual(restored.layout(in: area, config: config).first?.rect, area)
    }

    func testMovingOutOfAStackDetachesTheWindow() {
        let tree = stack([1, 2])
        XCTAssertEqual(tree.move(2, .right, area: area, config: config), .detached)
        XCTAssertEqual(tree.tiles.count, 2)
        XCTAssertEqual(tree.tile(containing: 1)?.isStack, true)
        XCTAssertEqual(tree.tile(containing: 2)?.isStack, false)
        XCTAssertEqual(frames(tree)[2], CGRect(x: 800, y: 0, width: 800, height: 1000))
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 28, width: 800, height: 972))
    }

    func testMovingTowardAPlainTileSwapsThem() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        XCTAssertEqual(tree.move(1, .right, area: area, config: config), .swapped)
        XCTAssertEqual(frames(tree)[2]?.minX, 0)
        XCTAssertEqual(frames(tree)[1]?.minX, 800)
        XCTAssertEqual(tree.move(1, .right, area: area, config: config), .none)
    }

    func testNeighborOnlyLooksInThatDirection() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        insert(tree, 3, focused: 2)
        let left = tree.tile(containing: 1)!
        XCTAssertTrue(tree.neighbor(of: left, .right, area: area, config: config) === tree.tile(containing: 2))
        XCTAssertNil(tree.neighbor(of: left, .left, area: area, config: config))
        let bottom = tree.tile(containing: 3)!
        XCTAssertTrue(tree.neighbor(of: bottom, .up, area: area, config: config) === tree.tile(containing: 2))
        XCTAssertTrue(tree.neighbor(of: bottom, .left, area: area, config: config) === left)
    }

    func testUnstackingGivesEachWindowItsOwnTile() {
        let tree = stack([1, 2, 3])
        tree.toggleStack(1, area: area, config: config)
        XCTAssertEqual(tree.tiles.count, 3)
        XCTAssertTrue(tree.tiles.allSatisfy { !$0.isStack && $0.windows.count == 1 })
    }

    func testStackAllGathersEveryWindowWithTheFocusedOneActive() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        insert(tree, 3, focused: 2)
        tree.toggleStackAll(2, area: area, config: config)
        XCTAssertEqual(tree.tiles.count, 1)
        XCTAssertEqual(tree.tiles.first?.windows, [1, 2, 3])
        XCTAssertEqual(tree.tiles.first?.isStack, true)
        XCTAssertEqual(tree.tiles.first?.activeWindow, 2)
        XCTAssertNil(tree.tiles.first?.parent)
    }

    func testStackAllAgainGivesEachWindowItsOwnTile() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        insert(tree, 3, focused: 2)
        tree.toggleStackAll(1, area: area, config: config)
        tree.toggleStackAll(1, area: area, config: config)
        XCTAssertEqual(tree.tiles.count, 3)
        XCTAssertTrue(tree.tiles.allSatisfy { !$0.isStack && $0.windows.count == 1 })
    }

    func testStackAllWithOneWindowLetsNewWindowsJoin() {
        let tree = LayoutTree()
        insert(tree, 1)
        tree.toggleStackAll(1, area: area, config: config)
        insert(tree, 2, focused: 1)
        XCTAssertEqual(tree.tiles.count, 1)
        XCTAssertEqual(tree.tiles.first?.windows, [1, 2])
    }

    func testStepStopsAtTheFirstAndLastTab() {
        let tree = stack([1, 2, 3])
        XCTAssertNil(tree.step(3, forward: true))
        XCTAssertEqual(tree.step(3, forward: false), 2)
        XCTAssertEqual(tree.step(2, forward: false), 1)
        XCTAssertNil(tree.step(1, forward: false))
        XCTAssertNil(LayoutTree().step(1, forward: true))
    }

    func testShiftArrowsMoveTheTabInsideTheStackAndDetachAtTheEdge() {
        let tree = stack([1, 2, 3])
        XCTAssertEqual(tree.move(3, .left, area: area, config: config), .reordered)
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [1, 3, 2])
        XCTAssertEqual(tree.tile(containing: 1)?.activeWindow, 3)
        XCTAssertEqual(tree.move(3, .left, area: area, config: config), .reordered)
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [3, 1, 2])
        XCTAssertEqual(tree.move(3, .left, area: area, config: config), .detached)
        XCTAssertEqual(tree.tiles.count, 2)
        XCTAssertEqual(frames(tree)[3]?.minX, 0)
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [1, 2])
    }

    func testUpAndDownStillTakeTheTabOutOfTheStack() {
        let tree = stack([1, 2])
        XCTAssertEqual(tree.move(1, .down, area: area, config: config), .detached)
        XCTAssertEqual(tree.tiles.count, 2)
    }

    func testDroppingATabPutsItAtThatPosition() {
        let tree = stack([1, 2, 3, 4])
        XCTAssertTrue(tree.moveTab(1, to: 2))
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [2, 3, 1, 4])
        XCTAssertEqual(tree.tile(containing: 1)?.activeWindow, 4)
        XCTAssertTrue(tree.moveTab(4, to: 0))
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [4, 2, 3, 1])
        XCTAssertFalse(tree.moveTab(4, to: 0))
    }

    func testReorderingKeepsHiddenTabsInPlace() {
        let tree = stack([1, 2, 3])
        tree.setHidden(2, true)
        tree.moveTab(3, to: 0)
        XCTAssertEqual(tree.tile(containing: 1)?.windows, [3, 2, 1])
        XCTAssertEqual(tree.layout(in: area, config: config).first?.frames.map(\.window), [3, 1])
    }

    func testCycleWrapsAround() {
        let tree = stack([1, 2])
        XCTAssertEqual(tree.cycle(2, forward: true), 1)
        XCTAssertEqual(tree.cycle(1, forward: false), 2)
    }

    func testActivateSelectsTheClickedTab() {
        let tree = stack([1, 2, 3])
        XCTAssertTrue(tree.activate(1))
        XCTAssertEqual(tree.tile(containing: 1)?.activeWindow, 1)
        XCTAssertFalse(tree.activate(1))
    }

    func testRemovingTheActiveTabKeepsAValidActive() {
        let tree = stack([1, 2, 3])
        tree.remove(3)
        XCTAssertEqual(tree.tile(containing: 1)?.activeWindow, 2)
        tree.activate(1)
        tree.remove(2)
        XCTAssertEqual(tree.tile(containing: 1)?.activeWindow, 1)
    }

    func testAdjustRatioGrowsTheFocusedTile() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        tree.adjustRatio(1, by: 0.1)
        XCTAssertEqual(frames(tree)[1]?.width, 960)
        tree.adjustRatio(2, by: 0.1)
        XCTAssertEqual(frames(tree)[1]?.width, 800)
    }

    func testToggleOrientationFlipsTheParentSplit() {
        let tree = LayoutTree()
        insert(tree, 1)
        insert(tree, 2, focused: 1)
        tree.toggleOrientation(1)
        XCTAssertEqual(frames(tree)[1], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(frames(tree)[2], CGRect(x: 0, y: 500, width: 1600, height: 500))
    }
}

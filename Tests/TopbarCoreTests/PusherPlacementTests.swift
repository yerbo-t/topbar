import CoreGraphics
import XCTest
@testable import TopbarCore

final class PusherPlacementTests: XCTestCase {
    private func item(_ x: Double, _ w: Double) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }

    func testAdjacentWhenNothingLiesBetween() {
        // выталкиватель кончается на 1100, знак начинается на 1100; другие значки левее выталкивателя и правее знака
        let others = [item(900, 40), item(1140, 36), item(1180, 60)]
        XCTAssertTrue(PusherPlacement.isAdjacent(pusherMaxX: 1100, glyphMinX: 1100, others: others))
    }

    func testNotAdjacentWhenAnIconSitsBetween() {
        // как у владельца: между выталкивателем (до 984) и знаком (с 1115) остались Hetzner и Claude
        let others = [item(990, 93), item(1081, 42), item(1160, 46)]
        XCTAssertFalse(PusherPlacement.isAdjacent(pusherMaxX: 984, glyphMinX: 1115, others: others))
    }

    func testSmallGapAndTouchingEdgesAreStillAdjacent() {
        XCTAssertTrue(PusherPlacement.isAdjacent(pusherMaxX: 1090, glyphMinX: 1100, others: []))
        // край соседнего окна, заходящий в допуск, значком «между» не считается
        XCTAssertTrue(PusherPlacement.isAdjacent(pusherMaxX: 1100, glyphMinX: 1100, others: [item(1099, 2)]))
        // а настоящий значок (от ~20 пунктов) между ними — считается
        XCTAssertFalse(PusherPlacement.isAdjacent(pusherMaxX: 1100, glyphMinX: 1130, others: [item(1102, 24)]))
    }

    func testTinyWindowsAreIgnored() {
        XCTAssertTrue(PusherPlacement.isAdjacent(pusherMaxX: 1000, glyphMinX: 1100, others: [item(1040, 1)]))
    }

    func testSameHorizontalRange() {
        XCTAssertTrue(PusherPlacement.sameHorizontalRange(item(1086, 36), item(1087, 36)))
        XCTAssertFalse(PusherPlacement.sameHorizontalRange(item(1086, 36), item(1050, 36)))
    }
    func testExpandedDividerIsFineWhenItStandsNextToTheGlyph() {
        XCTAssertFalse(PusherPlacement.needsRepairWhenExpanded(gap: 0, strayIcons: 0, repairedStrayCount: 0))
        XCTAssertFalse(PusherPlacement.needsRepairWhenExpanded(gap: 4, strayIcons: 0, repairedStrayCount: 0))
    }

    func testExpandedDividerIsRepairedOnceForAStrayIcon() {
        XCTAssertTrue(PusherPlacement.needsRepairWhenExpanded(gap: 24, strayIcons: 1, repairedStrayCount: 0))
    }

    func testExpandedDividerAcceptsASystemIconThatARepairDidNotRemove() {
        // индикатор микрофона система ставит между чертой и знаком сама: после одного пересоздания его принимаем, иначе черта мигала бы каждые 3 с
        XCTAssertFalse(PusherPlacement.needsRepairWhenExpanded(gap: 24, strayIcons: 1, repairedStrayCount: 1))
    }

    func testExpandedDividerIsRepairedAgainWhenAnotherIconAppears() {
        XCTAssertTrue(PusherPlacement.needsRepairWhenExpanded(gap: 48, strayIcons: 2, repairedStrayCount: 1))
    }

    func testExpandedDividerWithAGapButNoIconsBetweenIsStillRepaired() {
        XCTAssertTrue(PusherPlacement.needsRepairWhenExpanded(gap: 30, strayIcons: 0, repairedStrayCount: 0))
    }
}

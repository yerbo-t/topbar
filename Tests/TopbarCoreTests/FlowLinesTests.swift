import XCTest
@testable import TopbarCore

final class FlowLinesTests: XCTestCase {
    func testItemsWrapWhenTheLineIsFull() {
        XCTAssertEqual(FlowLines.count([100, 100, 100], available: 250, spacing: 10), 2)
        XCTAssertEqual(FlowLines.count([100, 100], available: 210, spacing: 10), 1, "ровно впритык — одна строка")
        XCTAssertEqual(FlowLines.count([100, 100], available: 209, spacing: 10), 2)
    }

    func testNothingTakesNoLinesAndAWideItemTakesItsOwn() {
        XCTAssertEqual(FlowLines.count([], available: 300, spacing: 6), 0)
        XCTAssertEqual(FlowLines.count([50, 400, 50], available: 300, spacing: 6), 3)
    }
}

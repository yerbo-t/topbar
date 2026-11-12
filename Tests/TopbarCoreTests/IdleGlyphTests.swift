import XCTest
@testable import TopbarCore

final class IdleGlyphTests: XCTestCase {
    func testLeftIsPreferredWhenThereIsRoom() {
        XCTAssertEqual(IdleGlyph.side(freeLeft: 60, freeRight: 60, needed: 34), .left)
    }

    func testRightWhenLeftIsTooTight() {
        XCTAssertEqual(IdleGlyph.side(freeLeft: 20, freeRight: 60, needed: 34), .right)
    }

    func testUnknownLeftFallsBackToRight() {
        XCTAssertEqual(IdleGlyph.side(freeLeft: nil, freeRight: 40, needed: 34), .right)
    }

    func testNoRoomAnywhereGivesNil() {
        XCTAssertNil(IdleGlyph.side(freeLeft: 10, freeRight: 12, needed: 34))
        XCTAssertNil(IdleGlyph.side(freeLeft: nil, freeRight: nil, needed: 34))
    }

    func testExactlyEnoughCounts() {
        XCTAssertEqual(IdleGlyph.side(freeLeft: 34, freeRight: nil, needed: 34), .left)
    }

    func testUnlimitedSpaceCounts() {
        XCTAssertEqual(IdleGlyph.side(freeLeft: .infinity, freeRight: .infinity, needed: 34), .left)
    }
}

import XCTest
@testable import TopbarCore

final class MenuBarEntryTests: XCTestCase {
    private func entry(_ id: String, x: Double, label: String = "", app: String = "App") -> MenuBarEntry {
        MenuBarEntry(id: id, appName: app, bundleId: "b.\(id)", label: label, minX: x, width: 30,
                     visibility: .visible)
    }

    func testPinnedGoFirstInOwnersOrderThenRestRightToLeft() {
        let items = [entry("a", x: 900), entry("b", x: 1000), entry("c", x: 1100), entry("d", x: 1200)]
        let ordered = MenuBarOrdering.order(items, pinned: ["b", "d"])
        XCTAssertEqual(ordered.map(\.id), ["b", "d", "c", "a"], "закреплённые — как выбрал владелец, остальные — справа налево")
    }

    func testMissingPinnedIsSkippedAndDuplicatesDoNotRepeat() {
        let items = [entry("a", x: 900), entry("b", x: 1000)]
        XCTAssertEqual(MenuBarOrdering.order(items, pinned: ["zzz", "a", "a"]).map(\.id), ["a", "b"])
    }

    func testPinAndUnpin() {
        XCTAssertEqual(MenuBarOrdering.pin("x", in: ["a", "b"]), ["a", "b", "x"])
        XCTAssertEqual(MenuBarOrdering.pin("b", in: ["a", "b", "c"], atTop: true), ["b", "a", "c"])
        XCTAssertEqual(MenuBarOrdering.pin("a", in: ["a", "b"]), ["b", "a"], "повторное закрепление не дублирует")
        XCTAssertEqual(MenuBarOrdering.unpin("a", from: ["a", "b"]), ["b"])
    }

    func testVisibilityByPosition() {
        XCTAssertEqual(MenuItemVisibility.classify(minX: 900, width: 30, notchRight: 848), .visible)
        XCTAssertEqual(MenuItemVisibility.classify(minX: 810, width: 34, notchRight: 848), .underNotch)
        XCTAssertEqual(MenuItemVisibility.classify(minX: -4200, width: 30, notchRight: 848), .pushedOff)
    }

    func testTitleAndSubtitle() {
        XCTAssertEqual(entry("a", x: 1, label: "Аккумулятор", app: "Пункт управления").title, "Аккумулятор")
        XCTAssertEqual(entry("a", x: 1, label: "Аккумулятор", app: "Пункт управления").subtitle, "Пункт управления")
        XCTAssertEqual(entry("a", x: 1, label: "", app: "AnyDesk").title, "AnyDesk")
        XCTAssertNil(entry("a", x: 1, label: "", app: "AnyDesk").subtitle)
        XCTAssertNil(entry("a", x: 1, label: "Claude", app: "Claude").subtitle, "подпись совпала с именем — не дублируем")
    }
}

import XCTest
@testable import TopbarCore

final class MenuBarEntryTests: XCTestCase {
    private func entry(_ id: String, x: Double, label: String = "", app: String = "App") -> MenuBarEntry {
        MenuBarEntry(id: id, appName: app, bundleId: "b.\(id)", label: label, minX: x, width: 30,
                     visibility: .visible)
    }

    private func ids(_ entries: [MenuBarEntry]) -> [String] { entries.map(\.id) }
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testPinnedGoFirstInOwnersOrderThenRestRightToLeft() {
        let items = [entry("a", x: 900), entry("b", x: 1000), entry("c", x: 1100), entry("d", x: 1200)]
        let sections = MenuBarOrdering.sections(items, prefs: MenuBarPrefs(pinned: ["b", "d"]))
        XCTAssertEqual(ids(sections.pinned), ["b", "d"], "закреплённые — как выбрал владелец")
        XCTAssertEqual(ids(sections.recent), ["c", "a"], "остальные без истории — справа налево, как в строке меню")
        XCTAssertTrue(sections.hidden.isEmpty)
    }

    func testMissingPinnedIsSkippedAndDuplicatesDoNotRepeat() {
        let items = [entry("a", x: 900), entry("b", x: 1000)]
        let sections = MenuBarOrdering.sections(items, prefs: MenuBarPrefs(pinned: ["zzz", "a", "a"]))
        XCTAssertEqual(ids(sections.pinned), ["a"])
        XCTAssertEqual(ids(sections.recent), ["b"])
    }

    func testRecentlyUsedComeFirstAmongTheRest() {
        let items = [entry("a", x: 900), entry("b", x: 1000), entry("c", x: 1100), entry("d", x: 1200)]
        var prefs = MenuBarPrefs()
        prefs.markUsed("a", at: at(100))
        prefs.markUsed("b", at: at(300))
        let sections = MenuBarOrdering.sections(items, prefs: prefs)
        XCTAssertEqual(ids(sections.recent), ["b", "a", "d", "c"], "кто работал последним — выше; без истории — справа налево после них")
    }

    func testUsageByApplicationCountsForItsIcons() {
        let items = [entry("a", x: 900), entry("b", x: 1000)]
        var prefs = MenuBarPrefs()
        prefs.markUsed("b.a", at: at(50))   // приложение стало активным: ключ — его идентификатор
        XCTAssertEqual(ids(MenuBarOrdering.sections(items, prefs: prefs).recent), ["a", "b"])
    }

    func testHiddenGoToTheirOwnGroupAndOutOfRecent() {
        let items = [entry("a", x: 900), entry("b", x: 1000), entry("c", x: 1100)]
        var prefs = MenuBarPrefs()
        prefs.toggleHidden("b")
        let sections = MenuBarOrdering.sections(items, prefs: prefs)
        XCTAssertEqual(ids(sections.hidden), ["b"])
        XCTAssertEqual(ids(sections.recent), ["c", "a"])
        prefs.toggleHidden("b")
        XCTAssertTrue(MenuBarOrdering.sections(items, prefs: prefs).hidden.isEmpty, "второй раз глаз возвращает значок")
    }

    func testPinningAHiddenIconShowsItAndHidingAPinnedOneUnpinsIt() {
        var prefs = MenuBarPrefs(pinned: ["a"], hidden: ["b"])
        prefs.togglePin("b")
        XCTAssertEqual(prefs.pinned, ["a", "b"])
        XCTAssertFalse(prefs.isHidden("b"))
        prefs.toggleHidden("a")
        XCTAssertEqual(prefs.pinned, ["b"])
        XCTAssertTrue(prefs.isHidden("a"))
    }

    func testPinnedWinsIfBothArePresentInStoredData() {
        let items = [entry("a", x: 900)]
        let sections = MenuBarOrdering.sections(items, prefs: MenuBarPrefs(pinned: ["a"], hidden: ["a"]))
        XCTAssertEqual(ids(sections.pinned), ["a"])
        XCTAssertTrue(sections.hidden.isEmpty)
    }

    func testPinAndUnpinAndMoveToTop() {
        var prefs = MenuBarPrefs(pinned: ["a", "b"])
        prefs.togglePin("x")
        XCTAssertEqual(prefs.pinned, ["a", "b", "x"])
        prefs.moveToTop("b")
        XCTAssertEqual(prefs.pinned, ["b", "a", "x"])
        prefs.togglePin("a")
        XCTAssertEqual(prefs.pinned, ["b", "x"], "повторное нажатие открепляет")
        prefs.moveToTop("b")
        XCTAssertEqual(prefs.pinned, ["b", "x"], "в верх уже стоящего ничего не дублирует")
    }

    func testUsageMemoryIsCapped() {
        var prefs = MenuBarPrefs()
        for i in 0..<(MenuBarPrefs.maxRemembered + 40) { prefs.markUsed("k\(i)", at: at(Double(i))) }
        XCTAssertEqual(prefs.lastUsed.count, MenuBarPrefs.maxRemembered)
        XCTAssertNil(prefs.lastUsed["k0"], "старейшие забываются")
        XCTAssertNotNil(prefs.lastUsed["k\(MenuBarPrefs.maxRemembered + 39)"])
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

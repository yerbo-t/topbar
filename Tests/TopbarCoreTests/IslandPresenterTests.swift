import CoreGraphics
import XCTest
@testable import TopbarCore

final class IslandPresenterTests: XCTestCase {
    var presenter = IslandPresenter()

    func session(_ id: String, _ status: SessionStatus, requests: [(String, Bool)] = [], host: String? = "Ghostty") -> Session {
        let queue = requests.map { (rid, cardable) in
            PermissionRequest(requestId: rid, sessionId: id, toolName: "Bash", summary: "Bash: x", detail: "x",
                              agentId: nil, agentType: nil, toolUseId: nil, receivedAt: Fx.t0, cardable: cardable)
        }
        return Session(sessionId: id, projectRoot: "/w/\(id)", project: id, branch: nil, status: status, currentAction: "",
                       pid: 1, processStartedAt: nil, hostApp: host, tty: nil, hints: [:], permissionMode: nil,
                       firstSeenAt: Fx.t0, lastEventAt: Fx.t0, running: [], unseenDone: false, queue: queue)
    }

    func testHiddenWithoutSessionsCollapsedWithThem() {
        XCTAssertEqual(presenter.mode, .hidden)
        presenter.update(sessions: [session("a", .working)])
        XCTAssertEqual(presenter.mode, .collapsed)
        presenter.toggleList()
        XCTAssertEqual(presenter.mode, .list)
        presenter.update(sessions: [])
        XCTAssertEqual(presenter.mode, .hidden)
        presenter.update(sessions: [session("a", .working)])
        XCTAssertEqual(presenter.mode, .collapsed, "список закрылся, когда сессий не осталось")
    }

    func testCardOpensForCardableRequestAndClosesWithIt() {
        presenter.update(sessions: [session("a", .waitingPermission, requests: [("r1", true)])])
        presenter.requestOpened("r1")
        XCTAssertEqual(presenter.mode, .card(requestId: "r1"))
        presenter.requestClosed("r1")
        XCTAssertEqual(presenter.mode, .collapsed)
    }

    func testCardDisappearsWhenRequestVanishesFromSessions() {
        presenter.update(sessions: [session("a", .waitingPermission, requests: [("r1", true)])])
        presenter.requestOpened("r1")
        presenter.update(sessions: [session("a", .working)])
        XCTAssertEqual(presenter.mode, .collapsed)
        XCTAssertNil(presenter.currentCardId)
    }

    func testQuestionRequestsNeverBecomeCards() {
        presenter.update(sessions: [session("a", .waitingPermission, requests: [("q1", false)])])
        presenter.requestOpened("q1")
        XCTAssertEqual(presenter.mode, .collapsed)
    }

    func testCardsShowOneByOneInArrivalOrder() {
        presenter.update(sessions: [
            session("a", .waitingPermission, requests: [("r1", true)]),
            session("b", .waitingPermission, requests: [("r2", true)]),
        ])
        presenter.requestOpened("r1")
        presenter.requestOpened("r2")
        XCTAssertEqual(presenter.currentCardId, "r1")
        XCTAssertEqual(presenter.queuedBehindCurrent, 1)
        presenter.requestClosed("r1")
        XCTAssertEqual(presenter.currentCardId, "r2")
        XCTAssertEqual(presenter.queuedBehindCurrent, 0)
    }

    func testDismissHidesCardWithoutAnswering() {
        presenter.update(sessions: [session("a", .waitingPermission, requests: [("r1", true)])])
        presenter.requestOpened("r1")
        presenter.dismissCard()
        XCTAssertEqual(presenter.mode, .collapsed)
    }

    func testClickOnWaitingRowOpensItsCardsFirst() {
        presenter.update(sessions: [
            session("a", .waitingPermission, requests: [("r1", true)]),
            session("b", .waitingPermission, requests: [("r2", true), ("r3", true)]),
        ])
        presenter.requestOpened("r1")
        presenter.openCards(forSession: "b")
        XCTAssertEqual(presenter.cardQueue, ["r2", "r3", "r1"])
        XCTAssertEqual(presenter.currentCardId, "r2")
    }

    func testSummaryTextOrderAndZerosOmitted() {
        presenter.update(sessions: [
            session("a", .working), session("b", .done), session("c", .waitingPermission),
            session("d", .idle), session("e", .working),
        ])
        XCTAssertEqual(presenter.summaryText, "1 ждёт · 1 готово · 2 работает")
        XCTAssertEqual(presenter.topStatus, .waitingPermission)
        presenter.update(sessions: [session("d", .idle), session("e", .idle)])
        XCTAssertEqual(presenter.summaryText, "2 простаивает", "когда больше нечего показать, остров не пустой")
        XCTAssertEqual(presenter.topStatus, .idle)
    }

    func testWatchPolicyMatchesHostApp() {
        let s = session("a", .working, host: "Ghostty")
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: "com.mitchellh.ghostty"))
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: "com.apple.Safari"))
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: nil))
        XCTAssertFalse(WatchPolicy.isWatching(session("b", .working, host: nil), frontmostBundleId: "com.mitchellh.ghostty"))
        XCTAssertTrue(WatchPolicy.isWatching(session("c", .working, host: "VS Code"), frontmostBundleId: "com.microsoft.VSCode"))
    }

    // MARK: уши свёрнутого острова

    private func chip(_ status: SessionStatus, _ count: Int, _ word: String) -> SummaryChip {
        SummaryChip(status: status, count: count, text: "\(count) \(word)")
    }
    private let fixedMeasure: (String) -> CGFloat = { CGFloat($0.count) * 7 }   // 7 пт на символ

    func testEarsAreFullWhenThereIsRoomOrNoIcons() {
        let chips = [chip(.waitingPermission, 1, "ждёт"), chip(.working, 2, "работает")]
        let free = EarLayout.make(chips: chips, availableRight: nil, measure: fixedMeasure)
        XCTAssertEqual(free.style, .full)
        XCTAssertEqual(free.leftWidth, free.rightWidth, "уши симметричны")
        let roomy = EarLayout.make(chips: chips, availableRight: 400, measure: fixedMeasure)
        XCTAssertEqual(roomy, free)
    }

    func testEarsShrinkToFitBeforeIcons() {
        let chips = [chip(.waitingPermission, 1, "ждёт"), chip(.working, 2, "работает")]
        let full = EarLayout.make(chips: chips, availableRight: nil, measure: fixedMeasure)
        for room in [full.rightWidth - 1, 60, 40] as [CGFloat] {
            let e = EarLayout.make(chips: chips, availableRight: room, measure: fixedMeasure)
            XCTAssertLessThanOrEqual(e.rightWidth, room, "правое ухо не заходит на значки (место \(room))")
            XCTAssertNotEqual(e.style, .full)
        }
        XCTAssertEqual(EarLayout.make(chips: chips, availableRight: 40, measure: fixedMeasure).style, .compact)
        XCTAssertEqual(EarLayout.make(chips: chips, availableRight: 32, measure: fixedMeasure).style, .dots)
    }

    func testWhenRightEarCannotFitEverythingMovesLeft() {
        let chips = [chip(.waitingPermission, 1, "ждёт"), chip(.done, 1, "готово"), chip(.working, 2, "работает")]
        let e = EarLayout.make(chips: chips, availableRight: 20, measure: fixedMeasure)
        XCTAssertEqual(e.style, .merged)
        XCTAssertEqual(e.rightWidth, 0)
        XCTAssertEqual(e.left.count, 3)
    }

    func testThreeChipsAreSplitEvenlyBetweenEars() {
        let chips = [chip(.waitingPermission, 1, "ждёт"), chip(.done, 1, "готово"), chip(.working, 2, "работает")]
        let e = EarLayout.make(chips: chips, availableRight: nil, measure: fixedMeasure)
        XCTAssertEqual(e.left.count, 2)
        XCTAssertEqual(e.right.count, 1)
        let tight = EarLayout.make(chips: chips, availableRight: 36, measure: fixedMeasure)
        XCTAssertEqual(tight.style, .dots, "одна точка справа помещается в 36 пт")
        XCTAssertLessThanOrEqual(tight.rightWidth, 36)
    }

    func testSingleChipKeepsTextOnTheLeftAndCapsTheRight() {
        let e = EarLayout.make(chips: [chip(.working, 1, "работает")], availableRight: 36, measure: fixedMeasure)
        XCTAssertEqual(e.style, .full)
        XCTAssertEqual(e.right.count, 0)
        XCTAssertEqual(e.rightWidth, 36)
        XCTAssertGreaterThan(e.leftWidth, 36)
    }

    func testWatchPolicyComparesTerminalWhenKnown() {
        var s = session("a", .working, host: "Ghostty")
        s.tty = "ttys004"
        let ghostty = "com.mitchellh.ghostty"
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: ghostty, focusedTTY: "/dev/ttys004"))
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: ghostty, focusedTTY: "/dev/ttys001"),
                       "Ghostty активен, но в фокусе другая вкладка: на эту сессию не смотрят")
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: ghostty, focusedTTY: nil),
                      "не удалось узнать фокус — решаем по приложению")
        s.tty = nil
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: ghostty, focusedTTY: "/dev/ttys001"),
                      "терминал сессии неизвестен — решаем по приложению")
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: "com.apple.Safari", focusedTTY: "/dev/ttys004"))
    }

    func testSameForDisplayIgnoresInvisibleFields() {
        let a = session("a", .working)
        var b = a
        b.lastEventAt = Fx.t0.addingTimeInterval(99)
        b.pid = 777
        b.hints = ["GHOSTTY_SURFACE_ID": "x"]
        b.running = [RunningTool(toolUseId: "u", toolName: "Bash", fingerprint: "", startedAt: Fx.t0)]
        XCTAssertTrue(a.sameForDisplay(as: b))
        var c = a
        c.currentAction = "Bash: ls"
        XCTAssertFalse(a.sameForDisplay(as: c))
        var d = a
        d.status = .done
        XCTAssertFalse(Session.sameForDisplay([a], [d]))
        XCTAssertFalse(Session.sameForDisplay([a], [a, a]))
        XCTAssertTrue(Session.sameForDisplay([], []))
    }

    func testSettingsFileKeepsSymlinkAndMode() throws {
        let dir = Fx.tempDir()
        let target = dir.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try SettingsFile.write(Data(#"{"a":1}"#.utf8), to: link.path)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "симлинк остался")
        XCTAssertEqual(String(decoding: SettingsFile.read(link.path) ?? Data(), as: UTF8.self), #"{"a":1}"#)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWatchPolicyUsesHostBundleIdForAnyTerminal() {
        var s = session("t", .working, host: "Terminal")
        s.hostBundleId = "com.apple.Terminal"
        s.tty = "ttys002"
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: "com.apple.Terminal"), "терминал без точного определения — по приложению")
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: "com.mitchellh.ghostty"))
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: "com.apple.Terminal", focusedTTY: "/dev/ttys002"))
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: "com.apple.Terminal", focusedTTY: "/dev/ttys009"),
                       "другая вкладка того же терминала")
    }

    func testWatchPolicyWorksForUnknownHostWithOnlyBundleId() {
        var s = session("u", .working, host: nil)
        s.hostBundleId = "com.example.NewTerminal"
        XCTAssertTrue(WatchPolicy.isWatching(s, frontmostBundleId: "com.example.NewTerminal"))
        XCTAssertFalse(WatchPolicy.isWatching(s, frontmostBundleId: "com.apple.Terminal"))
    }

    // MARK: обложка музыки в правом ухе

    func testMusicThumbGoesToTheRightEarWhenLeftHasWords() {
        let one = EarLayout.make(chips: [chip(.working, 2, "работает")], availableRight: nil, withMedia: true, measure: fixedMeasure)
        XCTAssertTrue(one.showsMedia, "слева слово, значит обложка справа")
        XCTAssertGreaterThanOrEqual(one.rightWidth, EarLayout.minThumbEar)
        XCTAssertEqual(one.style, .full, "слова слева остаются полными")
    }

    func testMusicThumbIsSkippedWhenThereIsNoRoomRight() {
        let tight = EarLayout.make(chips: [chip(.working, 2, "работает")], availableRight: 30, withMedia: true, measure: fixedMeasure)
        XCTAssertFalse(tight.showsMedia)
        XCTAssertLessThanOrEqual(tight.rightWidth, 30)
    }

    func testMusicThumbWidensTheRightEarWhenBothEarsHaveChips() {
        let chips = [chip(.working, 1, "работает"), chip(.waitingPermission, 1, "ждёт")]
        let without = EarLayout.make(chips: chips, availableRight: nil, measure: fixedMeasure)
        let with = EarLayout.make(chips: chips, availableRight: nil, withMedia: true, measure: fixedMeasure)
        XCTAssertTrue(with.showsMedia)
        XCTAssertEqual(with.rightWidth, without.rightWidth + EarLayout.mediaSlot)
        XCTAssertEqual(with.leftWidth, without.leftWidth)
        let room = without.rightWidth + EarLayout.mediaSlot - 1
        XCTAssertFalse(EarLayout.make(chips: chips, availableRight: room, withMedia: true, measure: fixedMeasure).showsMedia,
                       "не хватает места под обложку — слова важнее")
    }

    func testNoMusicThumbWithoutMediaOrWithoutChips() {
        XCTAssertFalse(EarLayout.make(chips: [chip(.working, 1, "работает")], availableRight: nil, measure: fixedMeasure).showsMedia)
        XCTAssertFalse(EarLayout.make(chips: [], availableRight: nil, withMedia: true, measure: fixedMeasure).showsMedia)
    }
}

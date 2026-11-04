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
        presenter.update(sessions: [session("d", .idle)])
        XCTAssertEqual(presenter.summaryText, "")
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
}

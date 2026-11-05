import XCTest
@testable import TopbarCore

final class SessionStoreTests: XCTestCase {
    var store = SessionStore(branchProvider: { _ in "feat/x" })
    let now = Fx.t0

    func status(_ sid: String = "s1") -> SessionStatus? { store.sessions[sid]?.status }

    func testLifecycleStartPromptToolStop() {
        store.apply(Fx.msg("SessionStart", source: "startup"), now: now)
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.project, "topbar")
        XCTAssertEqual(store.sessions["s1"]?.branch, "feat/x")
        XCTAssertEqual(store.sessions["s1"]?.hostApp, "Ghostty")

        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        XCTAssertEqual(status(), .working)

        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("pnpm test\nsecond line")), now: now)
        XCTAssertEqual(store.sessions["s1"]?.currentAction, "Bash: pnpm test")
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, true)

        let effects = store.apply(Fx.msg("Stop"), now: now)
        XCTAssertEqual(status(), .done)
        XCTAssertEqual(store.sessions["s1"]?.unseenDone, true)
        XCTAssertEqual(effects, [.sessionBecameDone(sessionId: "s1")])
    }

    func testPermissionRequestOpensAndPostToolUseClosesIt() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("mkdir x")), now: now)
        let opened = store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("mkdir x")), now: now)
        XCTAssertEqual(status(), .waitingPermission)
        guard case .requestOpened(let r) = opened.first else { return XCTFail("нет requestOpened") }
        XCTAssertEqual(r.requestId, "r1")
        XCTAssertEqual(r.summary, "Bash: mkdir x")

        let closed = store.apply(Fx.msg("PostToolUse", tool: "Bash"), now: now)
        XCTAssertEqual(closed, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(status(), .working)
        XCTAssertTrue(store.sessions["s1"]!.queue.isEmpty)
    }

    func testTwoRequestsKeepSessionWaitingUntilBothClosed() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("a")), now: now)
        store.apply(Fx.msg("PermissionRequest", req: "r2", tool: "Write"), now: now)
        store.apply(Fx.msg("PostToolUse", tool: "Bash"), now: now)
        XCTAssertEqual(status(), .waitingPermission)
        XCTAssertEqual(store.sessions["s1"]?.queue.map(\.requestId), ["r2"])
        store.apply(Fx.msg("PostToolUse", tool: "Write"), now: now)
        XCTAssertEqual(status(), .working)
    }

    func testResolveFromIslandRemovesRequestAndReturnsToWorking() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        XCTAssertTrue(store.resolve(requestId: "r1"))
        XCTAssertEqual(status(), .working)
        XCTAssertFalse(store.resolve(requestId: "r1"))
    }

    func testInterruptReturnsToIdleAndClosesRequests() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        let effects = store.apply(Fx.msg("PostToolUseFailure", tool: "Bash", interrupt: true), now: now)
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(store.sessions["s1"]?.currentAction, "Прервано")
    }

    func testStopFailureGoesIdleWithErrorNote() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("StopFailure"), now: now)
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.currentAction, "Ошибка API")
    }

    func testCompactDoesNotResetWorkingButClearDoes() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("SessionStart", source: "compact"), now: now)
        XCTAssertEqual(status(), .working)
        store.apply(Fx.msg("SessionStart", source: "clear"), now: now)
        XCTAssertEqual(status(), .idle)
    }

    func testSessionEndRemovesSessionAndClosesRequests() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        let effects = store.apply(Fx.msg("SessionEnd"), now: now)
        XCTAssertNil(store.sessions["s1"])
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1"), .sessionRemoved(sessionId: "s1")])
    }

    func testUnknownSessionFirstEventCreatesItWithMatchingStatus() {
        store.apply(Fx.msg("PermissionRequest", sid: "late", req: "r9", tool: "Bash", pid: 101), now: now)
        XCTAssertEqual(status("late"), .waitingPermission)
        store.apply(Fx.msg("PostToolUse", sid: "other", tool: "Bash", pid: 102), now: now)
        XCTAssertEqual(status("other"), .working)
        store.apply(Fx.msg("Stop", sid: "third", pid: 103), now: now)
        XCTAssertEqual(status("third"), .done)
    }

    func testPostToolUseAfterStopDoesNotReviveSession() {
        store.apply(Fx.msg("Stop"), now: now)
        store.apply(Fx.msg("PostToolUse", tool: "Bash"), now: now)
        XCTAssertEqual(status(), .done)
    }

    func testSweepQuietOnlyWhenNoToolRunning() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        let later = now.addingTimeInterval(601)
        XCTAssertEqual(store.sweepQuiet(now: later), ["s1"])
        XCTAssertEqual(status(), .idle)

        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("sleep 900")), now: now)
        XCTAssertEqual(store.sweepQuiet(now: later), [])
        XCTAssertEqual(status(), .working)
    }

    func testMarkViewedClearsDoneMark() {
        store.apply(Fx.msg("Stop"), now: now)
        store.markViewed(sessionId: "s1")
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.unseenDone, false)
    }

    func testSummaryCountsAndTopStatusPriority() {
        // Разные сессии — разные процессы (иначе автомат посчитает прежнюю призраком).
        store.apply(Fx.msg("UserPromptSubmit", sid: "a", pid: 101), now: now)
        store.apply(Fx.msg("Stop", sid: "b", pid: 102), now: now)
        store.apply(Fx.msg("SessionStart", sid: "c", source: "startup", pid: 103), now: now)
        XCTAssertEqual(store.summary(), Summary(waiting: 0, working: 1, done: 1, idle: 1, top: .done))
        store.apply(Fx.msg("PermissionRequest", sid: "a", req: "r", tool: "Bash", pid: 101), now: now)
        XCTAssertEqual(store.summary().top, .waitingPermission)
        XCTAssertEqual(store.snapshot().first?.sessionId, "a")
    }

    func testDuplicateTitlesGetSuffix() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "a", pid: 101), now: now)
        store.apply(Fx.msg("UserPromptSubmit", sid: "b", pid: 102), now: now.addingTimeInterval(5))
        let titles = SessionStore.displayTitles(store.snapshot())
        XCTAssertEqual(titles["a"], "topbar · feat/x")
        XCTAssertEqual(titles["b"], "topbar · feat/x #2")
    }

    func testRemoveWithoutSessionEnd() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        let effects = store.remove(sessionId: "s1")
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1"), .sessionRemoved(sessionId: "s1")])
    }

    func testPolicyDoesNotInterceptQuestionTools() {
        XCTAssertFalse(PermissionPolicy.intercepts(toolName: "AskUserQuestion"))
        XCTAssertFalse(PermissionPolicy.intercepts(toolName: "ExitPlanMode"))
        XCTAssertTrue(PermissionPolicy.intercepts(toolName: "Bash"))
    }

    // MARK: привязка запросов к вызовам, параллельные инструменты

    func testFinishedPreApprovedToolDoesNotCloseAnotherPendingRequest() {
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("ls"), toolUseId: "u1"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("rm x"), toolUseId: "u2"), now: now)
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("rm x")), now: now)
        XCTAssertEqual(store.sessions["s1"]?.queue.first?.toolUseId, "u2")

        store.apply(Fx.msg("PostToolUse", tool: "Bash", toolUseId: "u1"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.queue.count, 1, "чужой PostToolUse не закрывает запрос")
        XCTAssertEqual(status(), .waitingPermission)

        let effects = store.apply(Fx.msg("PostToolUse", tool: "Bash", toolUseId: "u2"), now: now)
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(status(), .working)
    }

    func testParallelToolsAreTrackedIndividually() {
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("sleep 600"), toolUseId: "u1"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Read", toolUseId: "u2"), now: now)
        store.apply(Fx.msg("PostToolUse", tool: "Read", toolUseId: "u2"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, true, "быстрый Read не снимает признак долгой команды")
        store.apply(Fx.msg("PostToolUse", tool: "Bash", toolUseId: "u1"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, false)
    }

    func testLaterPreToolUseClosesRequestsAnsweredInTerminal() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("a")), now: now)
        // Параллельный вызов стартует сразу: запрос ещё актуален.
        store.apply(Fx.msg("PreToolUse", tool: "Read"), now: now.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]?.queue.count, 1)
        // Через 5 с сессия начала новый инструмент: значит, на запрос уже ответили (например, отказом в терминале).
        let effects = store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("b")), now: now.addingTimeInterval(5))
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(status(), .working)
    }

    func testStaleBashWithoutChildProcessesGoesIdleAfterEsc() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("sleep 600"), toolUseId: "u1"), now: now)
        let later = now.addingTimeInterval(21)
        XCTAssertEqual(store.sweepQuiet(now: later, hasChildProcess: { _ in true }), [], "команда ещё идёт")
        XCTAssertEqual(store.sweepQuiet(now: later, hasChildProcess: { _ in false }), ["s1"])
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, false)
    }

    func testNonBashToolIsNotTreatedAsStaleByChildCheck() {
        store.apply(Fx.msg("PreToolUse", tool: "WebFetch", toolUseId: "u1"), now: now)
        XCTAssertEqual(store.sweepQuiet(now: now.addingTimeInterval(120), hasChildProcess: { _ in false }), [])
        XCTAssertEqual(status(), .working)
    }

    // MARK: идентичность процесса

    func testLateSessionEndFromOldProcessDoesNotKillResumedSession() {
        store.apply(Fx.msg("SessionStart", source: "startup", pid: 100, started: 1000), now: now)
        store.apply(Fx.msg("SessionStart", source: "resume", pid: 200, started: 2000), now: now)
        XCTAssertEqual(store.sessions["s1"]?.pid, 200)
        let effects = store.apply(Fx.msg("SessionEnd", pid: 100, started: 1000), now: now)
        XCTAssertEqual(effects, [])
        XCTAssertNotNil(store.sessions["s1"])
        store.apply(Fx.msg("SessionEnd", pid: 200, started: 2000), now: now)
        XCTAssertNil(store.sessions["s1"])
    }

    func testNewSessionOnSameProcessRemovesGhost() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "old", pid: 100, started: 1000), now: now)
        let effects = store.apply(Fx.msg("SessionStart", sid: "new", source: "clear", pid: 100, started: 1000), now: now)
        XCTAssertEqual(effects, [.sessionRemoved(sessionId: "old")])
        XCTAssertNil(store.sessions["old"])
        XCTAssertNotNil(store.sessions["new"])
    }

    func testUnknownPidNeverTriggersGhostRemoval() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "a", pid: 0, started: nil), now: now)
        store.apply(Fx.msg("UserPromptSubmit", sid: "b", pid: 0, started: nil), now: now)
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testSessionEndForUnknownSessionIsNoop() {
        XCTAssertEqual(store.apply(Fx.msg("SessionEnd", sid: "never-seen"), now: now), [])
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: содержимое запроса

    func testRequestKeepsFullCommandAndAgentType() {
        let command = "echo hi\nrm -rf ~/important"
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash(command), agentType: "general-purpose"), now: now)
        let r = store.sessions["s1"]!.queue[0]
        XCTAssertEqual(r.summary, "Bash: echo hi")
        XCTAssertEqual(r.detail, command, "владелец видит всю команду, а не первую строку")
        XCTAssertEqual(r.agentType, "general-purpose")
        XCTAssertTrue(r.cardable)
    }

    func testVeryLongInputIsTruncatedWithNote() {
        let command = String(repeating: "a", count: 9000)
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash(command)), now: now)
        let detail = store.sessions["s1"]!.queue[0].detail
        XCTAssertTrue(detail.hasSuffix("показано не всё"))
        XCTAssertLessThan(detail.count, 4100)
    }

    func testQuestionToolMakesSessionWaitButWithoutCard() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "AskUserQuestion"), now: now)
        XCTAssertEqual(status(), .waitingPermission)
        XCTAssertFalse(store.sessions["s1"]!.queue[0].cardable)
    }

    // MARK: хост сессии

    func testHostComesFromBundleIdWhenThereIsNoTermProgram() {
        var m = Fx.msg("UserPromptSubmit", term: nil)
        m.hostBundleId = "com.microsoft.VSCode"
        store.apply(m, now: now)
        XCTAssertEqual(store.sessions["s1"]?.hostApp, "VS Code", "расширение VS Code: нет TERM_PROGRAM, есть приложение")
        XCTAssertEqual(SessionStore.hostName(nil, bundleId: "com.mitchellh.ghostty"), "Ghostty")
        XCTAssertNil(SessionStore.hostName(nil, bundleId: "com.apple.Terminal"))
        XCTAssertEqual(SessionStore.hostName("vscode", bundleId: nil), "VS Code")
    }
}

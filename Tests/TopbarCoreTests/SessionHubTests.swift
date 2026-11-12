import XCTest
@testable import TopbarCore

final class SessionHubTests: XCTestCase {
    func hook(_ name: String, sid: String = "s1", tool: String? = nil, input: [String: Any] = ["command": "mkdir x"],
              extra: [String: Any] = [:]) -> Data {
        var d: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": "/work/topbar", "permission_mode": "default"]
        if let tool { d["tool_name"] = tool; d["tool_input"] = input }
        extra.forEach { d[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    func bridge(_ data: Data, path: String, env: [String: String] = [:], decision: Double = 5) -> Data? {
        // Живой процесс сессии — сам тест: так проверка живости не уберёт сессию.
        var environment = ["CLAUDE_PID": "\(getpid())"]
        env.forEach { environment[$0.key] = $0.value }
        return BridgeRunner.run(stdin: data, environment: environment, parentPid: 1,
                                socketPath: path, decisionTimeout: decision)
    }

    func makeHub(path: String) -> SessionHub {
        SessionHub(socketPath: path, livenessInterval: 3600, branchProvider: { _ in "main" })
    }

    /// Запрос разрешения в фоне: возвращает «ответ моста» через expectation.
    func requestInBackground(_ path: String, tool: String = "Bash", sid: String = "s1",
                             env: [String: String] = [:], timeout: Double = 20) -> (done: XCTestExpectation, output: () -> Data??) {
        let done = expectation(description: "bridge finished")
        var result: Data?? = .none
        DispatchQueue.global().async {
            result = .some(self.bridge(self.hook("PermissionRequest", sid: sid, tool: tool), path: path, env: env, decision: timeout))
            done.fulfill()
        }
        return (done, { result })
    }

    func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    func decision(_ data: Data?) -> String? {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specific = obj["hookSpecificOutput"] as? [String: Any],
              let d = specific["decision"] as? [String: Any] else { return nil }
        return d["behavior"] as? String
    }

    // MARK: решения и закрытие карточек

    func testCardDecisionReachesBridgeAsAllow() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.onRequestOpened = { req, _ in hub.decide(requestId: req.requestId, allow: true) }
        try hub.start()
        defer { hub.stop() }

        _ = bridge(hook("UserPromptSubmit"), path: path)
        let out = bridge(hook("PermissionRequest", tool: "Bash"), path: path)
        XCTAssertEqual(decision(out), "allow")
        hub.flush()
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testDenyReachesBridgeWithMessage() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.onRequestOpened = { req, _ in hub.decide(requestId: req.requestId, allow: false, denyMessage: "нельзя") }
        try hub.start()
        defer { hub.stop() }
        let out = bridge(hook("PermissionRequest", tool: "Bash"), path: path)
        XCTAssertEqual(decision(out), "deny")
        XCTAssertTrue(String(decoding: out ?? Data(), as: UTF8.self).contains("нельзя"))
    }

    func testPostToolUseClosesCardAndReleasesBridge() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let closed = expectation(description: "closed")
        hub.onRequestClosed = { _ in closed.fulfill() }
        try hub.start()
        defer { hub.stop() }

        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.status == .waitingPermission }
        // Владелец ответил в терминале: приходит PostToolUse.
        _ = bridge(hook("PostToolUse", tool: "Bash"), path: path)
        wait(for: [closed, pending.done], timeout: 3)
        XCTAssertEqual(pending.output(), .some(nil), "мост выходит без решения")
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testDecideAfterTerminalAnswerIsReportedAsNotDelivered() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var requestId: String?
        let opened = expectation(description: "opened")
        hub.onRequestOpened = { r, _ in requestId = r.requestId; opened.fulfill() }
        try hub.start()
        defer { hub.stop() }
        let pending = requestInBackground(path)
        wait(for: [opened], timeout: 2)
        _ = bridge(hook("PostToolUse", tool: "Bash"), path: path)
        wait(for: [pending.done], timeout: 3)

        let reported = expectation(description: "completion")
        hub.decide(requestId: requestId!, allow: true) { delivered in
            XCTAssertFalse(delivered)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 2)
    }

    func testAutoOpenDeciderFalseKeepsChannelSoRowClickCanStillDecide() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.autoOpenDecider = { _, _, done in done(false) }   // владелец смотрит на сессию
        var autoOpened = false
        hub.onRequestOpened = { _, _ in autoOpened = true }
        try hub.start()
        defer { hub.stop() }

        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.queue.isEmpty == false }
        hub.flush()
        XCTAssertFalse(autoOpened, "остров не раскрывается сам")
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission)
        // Клик по строке: карточку открывают вручную и отвечают по идентификатору из снимка.
        let id = try XCTUnwrap(hub.snapshot().first?.queue.first?.requestId)
        hub.decide(requestId: id, allow: true)
        wait(for: [pending.done], timeout: 3)
        XCTAssertEqual(decision(pending.output() ?? nil), "allow")
    }

    func testBridgeDisconnectClosesCard() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let opened = expectation(description: "opened")
        let closed = expectation(description: "closed")
        hub.onRequestOpened = { _, _ in opened.fulfill() }
        hub.onRequestClosed = { _ in closed.fulfill() }
        try hub.start()
        defer { hub.stop() }

        let fd = try XCTUnwrap(SocketClient.connect(path: path, timeout: 1))
        let msg = BridgeMessage(requestId: "dead-bridge", event: HookEvent("PermissionRequest", sessionId: "s1", cwd: "/work/topbar", toolName: "Bash", toolInput: Fx.bash("ls")), pid: getpid())
        XCTAssertTrue(SocketClient.writeAll(fd, try Wire.encode(msg)))
        XCTAssertNotNil(SocketClient.readLine(fd, timeout: 1))
        wait(for: [opened], timeout: 2)
        close(fd) // хук истёк или мост убит
        wait(for: [closed], timeout: 2)
    }

    func testDuplicateRequestIdIsRejectedWithoutStealingChannel() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let opened = expectation(description: "opened")
        hub.onRequestOpened = { _, _ in opened.fulfill() }
        try hub.start()
        defer { hub.stop() }

        func send(_ id: String) throws -> Int32 {
            let fd = try XCTUnwrap(SocketClient.connect(path: path, timeout: 1))
            let msg = BridgeMessage(requestId: id, event: HookEvent("PermissionRequest", sessionId: "s1", cwd: "/work/topbar", toolName: "Bash", toolInput: Fx.bash("ls")), pid: getpid())
            XCTAssertTrue(SocketClient.writeAll(fd, try Wire.encode(msg)))
            XCTAssertNotNil(SocketClient.readLine(fd, timeout: 1)) // ack
            return fd
        }
        let first = try send("same-id")
        wait(for: [opened], timeout: 2)
        let second = try send("same-id")
        let reply = try XCTUnwrap(SocketClient.readLine(second, timeout: 1))
        XCTAssertEqual(try Wire.decode(CoreReply.self, line: reply).kind, .none)
        close(second)

        hub.decide(requestId: "same-id", allow: true)
        let answer = try XCTUnwrap(SocketClient.readLine(first, timeout: 2))
        XCTAssertEqual(try Wire.decode(CoreReply.self, line: answer).behavior, "allow")
        close(first)
    }

    func testReleaseAllCardsFreesBridgesButKeepsStatus() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        try hub.start()
        defer { hub.stop() }
        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.status == .waitingPermission }
        hub.releaseAllCards()
        wait(for: [pending.done], timeout: 3)
        XCTAssertEqual(pending.output(), .some(nil))
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission, "диалог остался в терминале")
    }

    // MARK: убрать сессию из списка

    func testForgottenSessionLeavesTheListAndComesBackWithItsNextEvent() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        try hub.start()
        defer { hub.stop() }
        _ = bridge(hook("UserPromptSubmit"), path: path)
        XCTAssertEqual(hub.snapshot().map(\.sessionId), ["s1"])

        hub.forget(sessionId: "s1")
        XCTAssertTrue(hub.snapshot().isEmpty)

        _ = bridge(hook("Stop"), path: path)
        XCTAssertEqual(hub.snapshot().map(\.sessionId), ["s1"], "сессия жива и вернулась со своим событием")
    }

    func testForgettingASessionHandsItsOpenRequestBackToTheTerminal() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var closed: [String] = []
        hub.onRequestClosed = { closed.append($0) }
        try hub.start()
        defer { hub.stop() }
        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.status == .waitingPermission }

        hub.forget(sessionId: "s1")
        wait(for: [pending.done], timeout: 3)
        XCTAssertEqual(pending.output(), .some(nil), "без решения — Claude спросит в терминале")
        hub.flush()
        XCTAssertEqual(closed.count, 1)
        XCTAssertTrue(hub.snapshot().isEmpty)
    }

    // MARK: что не показываем карточкой

    func testQuestionToolWaitsWithoutCardAndReleasesBridge() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var opened = 0
        hub.onRequestOpened = { _, _ in opened += 1 }
        try hub.start()
        defer { hub.stop() }
        XCTAssertNil(bridge(hook("PermissionRequest", tool: "AskUserQuestion"), path: path))
        hub.flush()
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission, "сессия ждёт вас, просто без кнопок")
    }

    static let colorQuestion: [String: Any] = [
        "questions": [[
            "question": "Какой цвет?", "header": "Цвет", "multiSelect": false,
            "options": [["label": "Красный", "description": "Тёплый"], ["label": "Синий", "description": "Холодный"]],
        ]]
    ]

    func testAnswerFromTheCardReachesBridgeAsUpdatedInput() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.onRequestOpened = { req, _ in hub.answer(requestId: req.requestId, picks: ["Какой цвет?": ["Синий"]]) }
        try hub.start()
        defer { hub.stop() }
        let out = bridge(hook("PermissionRequest", tool: "AskUserQuestion", input: Self.colorQuestion), path: path)
        XCTAssertEqual(decision(out), "allow")
        let obj = try JSONSerialization.jsonObject(with: try XCTUnwrap(out)) as! [String: Any]
        let updated = ((obj["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any])["updatedInput"] as! [String: Any]
        XCTAssertEqual(updated["answers"] as? [String: String], ["Какой цвет?": "Синий"])
        XCTAssertEqual((updated["questions"] as? [[String: Any]])?.count, 1, "исходные вопросы остаются во вводе")
        hub.flush()
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testAnswerThatDoesNotFitTheQuestionIsRejectedAndCardStays() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let rejected = expectation(description: "rejected")
        var result: Bool?
        hub.onRequestOpened = { req, _ in
            hub.answer(requestId: req.requestId, picks: ["Какой цвет?": ["Жёлтый"]]) { ok in
                result = ok
                // Карточка жива: теперь отвечаем правильно.
                hub.answer(requestId: req.requestId, picks: ["Какой цвет?": ["Красный"]]) { _ in rejected.fulfill() }
            }
        }
        try hub.start()
        defer { hub.stop() }
        let out = bridge(hook("PermissionRequest", tool: "AskUserQuestion", input: Self.colorQuestion), path: path)
        wait(for: [rejected], timeout: 3)
        XCTAssertEqual(result, false)
        XCTAssertEqual(decision(out), "allow", "мост дождался верного ответа")
    }

    func testAnswerToARequestThatIsNotAQuestionIsRejected() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let answered = expectation(description: "answered")
        var result: Bool?
        hub.onRequestOpened = { req, _ in
            hub.answer(requestId: req.requestId, picks: ["Что-то?": ["Да"]]) { ok in
                result = ok
                hub.decide(requestId: req.requestId, allow: false) { _ in answered.fulfill() }
            }
        }
        try hub.start()
        defer { hub.stop() }
        _ = bridge(hook("PermissionRequest", tool: "Bash"), path: path)
        wait(for: [answered], timeout: 3)
        XCTAssertEqual(result, false)
    }

    func testUnattendedSessionsAreIgnoredCompletely() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var done = 0
        hub.onSessionDone = { _ in done += 1 }
        try hub.start()
        defer { hub.stop() }
        let env = ["CLAUDE_CODE_SESSION_ATTENDED": "0"]
        _ = bridge(hook("UserPromptSubmit", sid: "bg"), path: path, env: env)
        XCTAssertNil(bridge(hook("PermissionRequest", sid: "bg", tool: "Bash"), path: path, env: env))
        _ = bridge(hook("Stop", sid: "bg"), path: path, env: env)
        hub.flush()
        XCTAssertTrue(hub.snapshot().isEmpty, "ни строки, ни звука")
        XCTAssertEqual(done, 0)
    }

    // MARK: прочее

    func testSessionBecameDoneCallbackAndViewed() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let done = expectation(description: "done")
        hub.onSessionDone = { s in XCTAssertEqual(s.project, "topbar"); done.fulfill() }
        try hub.start()
        defer { hub.stop() }
        _ = bridge(hook("UserPromptSubmit"), path: path)
        _ = bridge(hook("Stop"), path: path)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(hub.snapshot().first?.status, .done)
        hub.markViewed(sessionId: "s1")
        hub.flush()
        XCTAssertEqual(hub.snapshot().first?.status, .idle)
    }

    func testCallbacksMayCallBackIntoHubWithoutDeadlock() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let called = expectation(description: "onChange")
        called.assertForOverFulfill = false
        hub.onChange = { _ in
            _ = hub.snapshot()
            hub.markViewed(sessionId: "s1")
            called.fulfill()
        }
        try hub.start()
        defer { hub.stop() }
        _ = bridge(hook("UserPromptSubmit"), path: path)
        wait(for: [called], timeout: 2)
    }

    func testDeadProcessIsRemovedByLivenessTick() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        try hub.start()
        defer { hub.stop() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        _ = bridge(hook("UserPromptSubmit"), path: path, env: ["CLAUDE_PID": "\(p.processIdentifier)"])
        XCTAssertEqual(hub.snapshot().count, 1)
        hub.tickNow()
        XCTAssertEqual(hub.snapshot().count, 1, "процесс жив")
        p.terminate()
        p.waitUntilExit()
        hub.tickNow()
        XCTAssertEqual(hub.snapshot().count, 0)
    }

    func testSessionWithUnknownPidIsNeverRemovedByLiveness() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        try hub.start()
        defer { hub.stop() }
        // CLAUDE_PID не передан, предка claude нет → pid 0.
        _ = BridgeRunner.run(stdin: hook("UserPromptSubmit"), environment: [:], parentPid: 1, socketPath: path)
        hub.tickNow()
        XCTAssertEqual(hub.snapshot().count, 1)
    }

    func testBashWithoutChildProcessesIsDroppedByTickButLiveOneIsKept() throws {
        for (hasChildren, expected) in [(false, SessionStatus.idle), (true, SessionStatus.working)] {
            let path = Fx.socketPath()
            let hub = SessionHub(socketPath: path, livenessInterval: 3600, staleToolAfter: 0,
                                 branchProvider: { _ in nil }, hasChildProcess: { _ in hasChildren })
            try hub.start()
            defer { hub.stop() }
            _ = bridge(hook("PreToolUse", tool: "Bash"), path: path)
            XCTAssertEqual(hub.snapshot().first?.status, .working)
            Thread.sleep(forTimeInterval: 0.05)
            hub.tickNow()
            XCTAssertEqual(hub.snapshot().first?.status, expected, "дочерние процессы: \(hasChildren)")
        }
    }

    // MARK: асинхронное решение об автораскрытии, лишние перерисовки

    func testAsyncDeciderOpensCardLaterWithoutBlockingTheHub() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.autoOpenDecider = { _, _, done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done(true) }
        }
        let opened = expectation(description: "opened")
        hub.onRequestOpened = { _, _ in opened.fulfill() }
        try hub.start()
        defer { hub.stop() }

        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.status == .waitingPermission }
        // Пока решение «думается», хаб принимает другие события без задержки.
        let started = Date()
        _ = bridge(hook("UserPromptSubmit", sid: "other"), path: path, env: ["CLAUDE_PID": "\(getppid())"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        wait(for: [opened], timeout: 2)
        hub.decide(requestId: try XCTUnwrap(hub.snapshot().first { $0.sessionId == "s1" }?.queue.first?.requestId), allow: true)
        wait(for: [pending.done], timeout: 3)
    }

    func testDeciderAnswerIsIgnoredIfRequestAlreadyClosed() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var finish: ((Bool) -> Void)?
        let asked = expectation(description: "asked")
        hub.autoOpenDecider = { _, _, done in finish = done; asked.fulfill() }
        var opened = 0
        hub.onRequestOpened = { _, _ in opened += 1 }
        try hub.start()
        defer { hub.stop() }

        let pending = requestInBackground(path)
        wait(for: [asked], timeout: 2)
        _ = bridge(hook("PostToolUse", tool: "Bash"), path: path)   // ответили в терминале, пока решали
        wait(for: [pending.done], timeout: 3)
        finish?(true)
        hub.flush()
        XCTAssertEqual(opened, 0, "карточку для уже закрытого запроса не открываем")
    }

    func testChangesInvisibleToTheUIDoNotTriggerOnChange() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var changes = 0
        hub.onChange = { _ in changes += 1 }
        try hub.start()
        defer { hub.stop() }

        _ = bridge(hook("UserPromptSubmit"), path: path)
        _ = bridge(hook("PreToolUse", tool: "Bash", input: ["command": "ls"]), path: path)
        hub.flush()
        let before = changes
        // PostToolUse не меняет ничего, что видно на экране: статус и действие прежние.
        _ = bridge(hook("PostToolUse", tool: "Bash", input: ["command": "ls"]), path: path)
        hub.flush()
        XCTAssertEqual(changes, before, "лишней перерисовки нет")
        _ = bridge(hook("Stop"), path: path)
        hub.flush()
        XCTAssertEqual(changes, before + 1, "а настоящее изменение доходит")
    }
}

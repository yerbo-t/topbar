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

    func testAutoOpenPolicyFalseKeepsChannelSoRowClickCanStillDecide() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.autoOpenPolicy = { _, _ in false }   // владелец смотрит на сессию
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
}

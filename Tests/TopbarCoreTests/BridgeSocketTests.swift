import XCTest
@testable import TopbarCore

final class BridgeSocketTests: XCTestCase {
    func hookJSON(_ name: String, tool: String? = nil) -> Data {
        var d: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/work/topbar"]
        if let tool { d["tool_name"] = tool; d["tool_input"] = ["command": "mkdir x"] }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    func run(_ data: Data, path: String, ack: Double = 0.3, decision: Double = 5, env: [String: String] = [:]) -> Data? {
        // parentPid: 1 (launchd) — предка `claude` нет, номер процесса сессии остаётся неизвестным.
        BridgeRunner.run(stdin: data, environment: env, parentPid: 1, socketPath: path,
                         ackTimeout: ack, decisionTimeout: decision)
    }

    func testNoServerMeansSilentNilQuickly() {
        let started = Date()
        XCTAssertNil(run(hookJSON("Stop"), path: Fx.socketPath()))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testPlainEventIsDeliveredAndAcked() {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        let got = expectation(description: "message")
        var received: BridgeMessage?
        let server = SocketServer(path: path, queue: q) { msg, ch in
            received = msg
            ch.send(.ack)
            got.fulfill()
        }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        let out = run(hookJSON("UserPromptSubmit"), path: path, env: ["TERM_PROGRAM": "ghostty", "CLAUDE_PROJECT_DIR": "/work/topbar"])
        XCTAssertNil(out)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(received?.event.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(received?.termProgram, "ghostty")
        XCTAssertEqual(received?.projectDir, "/work/topbar")
        XCTAssertFalse(received!.unattended)
    }

    func testUnattendedMarkers() {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        let got = expectation(description: "message")
        var received: BridgeMessage?
        let server = SocketServer(path: path, queue: q) { msg, ch in received = msg; ch.send(.ack); got.fulfill() }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        _ = run(hookJSON("Stop"), path: path, env: ["CLAUDE_CODE_SESSION_ATTENDED": "0", "CLAUDE_PID": "\(getpid())"])
        wait(for: [got], timeout: 2)
        XCTAssertTrue(received!.unattended)
        XCTAssertEqual(received?.pid, getpid())
    }

    func testPermissionDecisionAllowIsPrintedAsHookOutput() throws {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        let server = SocketServer(path: path, queue: q) { _, ch in
            ch.send(.ack)
            q.asyncAfter(deadline: .now() + 0.2) { ch.send(.allow()) }
        }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        let out = try XCTUnwrap(run(hookJSON("PermissionRequest", tool: "Bash"), path: path))
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let specific = obj["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((specific["decision"] as! [String: Any])["behavior"] as? String, "allow")
    }

    func testDenyCarriesMessage() throws {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        let server = SocketServer(path: path, queue: q) { _, ch in ch.send(.ack); ch.send(.deny("нельзя")) }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        let out = try XCTUnwrap(run(hookJSON("PermissionRequest", tool: "Bash"), path: path))
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let decision = (obj["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "нельзя")
    }

    func testNoneReplyMeansNoOutput() {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        let server = SocketServer(path: path, queue: q) { _, ch in ch.send(.ack); ch.send(.none) }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        XCTAssertNil(run(hookJSON("PermissionRequest", tool: "Bash"), path: path))
    }

    func testServerStoppingReleasesBridgeImmediately() {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        var serverRef: SocketServer!
        serverRef = SocketServer(path: path, queue: q) { _, ch in
            ch.send(.ack)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { serverRef.stop() }
        }
        XCTAssertNoThrow(try serverRef.start())
        defer { serverRef.stop() }
        let started = Date()
        XCTAssertNil(run(hookJSON("PermissionRequest", tool: "Bash"), path: path, decision: 20))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "мост не должен ждать до тайм-аута")
    }

    func testServerNotifiesWhenBridgeDisconnects() {
        let path = Fx.socketPath()
        let q = DispatchQueue(label: "t")
        let closed = expectation(description: "closed")
        let server = SocketServer(path: path, queue: q) { _, ch in
            ch.send(.ack)
            ch.onClose = { closed.fulfill() }
        }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        let fd = SocketClient.connect(path: path, timeout: 1)!
        _ = SocketClient.writeAll(fd, try! Wire.encode(Fx.msg("PermissionRequest", tool: "Bash")))
        _ = SocketClient.readLine(fd, timeout: 1)
        close(fd)
        wait(for: [closed], timeout: 2)
    }

    func testSocketPermissionsAreOwnerOnly() throws {
        let path = Fx.socketPath()
        let server = SocketServer(path: path, queue: DispatchQueue(label: "t")) { _, _ in }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int ?? 0) & 0o077, 0)
    }

    // MARK: процесс сессии, облегчение событий

    func receive(_ data: Data, env: [String: String] = [:]) -> BridgeMessage? {
        let path = Fx.socketPath()
        let got = expectation(description: "message")
        var received: BridgeMessage?
        let server = SocketServer(path: path, queue: DispatchQueue(label: "t")) { msg, ch in
            received = msg; ch.send(.ack); ch.send(.none); got.fulfill()
        }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        _ = run(data, path: path, env: env)
        wait(for: [got], timeout: 2)
        return received
    }

    func testUnknownSessionProcessGivesPidZeroNotTheParent() {
        let msg = receive(hookJSON("Stop"))
        XCTAssertEqual(msg?.pid, 0)
        XCTAssertNil(msg?.processStartedAt)
    }

    func testWindowHintsAreCollectedFromEnvironment() {
        let msg = receive(hookJSON("Stop"), env: ["GHOSTTY_RESOURCES_DIR": "/x", "VSCODE_PID": "7", "PATH": "/bin", "TERM_SESSION_ID": "w0t0p0"])
        XCTAssertEqual(msg?.hints, ["GHOSTTY_RESOURCES_DIR": "/x", "VSCODE_PID": "7", "TERM_SESSION_ID": "w0t0p0"])
    }

    func testPlainEventsCarrySlimToolInputButPermissionRequestsKeepItAll() {
        func data(_ name: String) -> Data {
            let d: [String: Any] = ["hook_event_name": name, "session_id": "s1", "tool_name": "Write",
                                    "tool_input": ["file_path": "/a.txt", "content": String(repeating: "z", count: 10_000)]]
            return try! JSONSerialization.data(withJSONObject: d)
        }
        let slim = receive(data("PreToolUse"))
        guard case .object(let a)? = slim?.event.toolInput else { return XCTFail() }
        XCTAssertEqual(Set(a.keys), ["file_path"])
        let full = receive(data("PermissionRequest"))
        guard case .object(let b)? = full?.event.toolInput else { return XCTFail() }
        XCTAssertEqual(b["content"]?.stringValue?.count, 10_000)
    }

    // MARK: надёжность сокета

    func testSecondServerDoesNotHijackLiveSocket() throws {
        let path = Fx.socketPath()
        let first = SocketServer(path: path, queue: DispatchQueue(label: "a")) { _, ch in ch.send(.ack) }
        try first.start()
        defer { first.stop() }
        let second = SocketServer(path: path, queue: DispatchQueue(label: "b")) { _, _ in }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? SocketError, .alreadyRunning) }
        // Первый по-прежнему отвечает.
        XCTAssertNil(run(hookJSON("Stop"), path: path))
    }

    func testStaleFileOnPathIsReplaced() throws {
        let path = Fx.socketPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = SocketServer(path: path, queue: DispatchQueue(label: "a")) { _, _ in }
        XCTAssertNoThrow(try server.start())
        server.stop()
    }

    func testStopDoesNotRemoveSocketOfAnotherInstance() throws {
        let path = Fx.socketPath()
        let a = SocketServer(path: path, queue: DispatchQueue(label: "a")) { _, ch in ch.send(.ack) }
        try a.start()
        unlink(path) // путь освободился (например, каталог почистили)
        let b = SocketServer(path: path, queue: DispatchQueue(label: "b")) { _, ch in ch.send(.ack) }
        try b.start()
        defer { b.stop() }
        a.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "сокет второго экземпляра не должен исчезнуть")
        XCTAssertNil(run(hookJSON("Stop"), path: path))
    }

    func testExistingDirectoryIsTightenedToOwnerOnly() throws {
        let dir = "/tmp/tb-dir-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let server = SocketServer(path: dir + "/hook.sock", queue: DispatchQueue(label: "a")) { _, _ in }
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        XCTAssertEqual((attrs[.posixPermissions] as? Int ?? 0) & 0o077, 0)
    }

    /// «Зависшее приложение»: сокет слушает, но никто не читает. Большое событие не должно держать мост.
    func testHungReceiverDoesNotBlockBridgePastDeadline() throws {
        let path = Fx.socketPath()
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        defer { close(fd); unlink(path) }

        let huge = ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Write",
                    "tool_input": ["file_path": "/a", "content": String(repeating: "q", count: 4_000_000)]] as [String: Any]
        let started = Date()
        XCTAssertNil(run(try JSONSerialization.data(withJSONObject: huge), path: path, ack: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}

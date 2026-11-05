import Foundation

/// Логика моста: прочитать событие хука, передать ядру, при запросе разрешения дождаться решения.
public enum BridgeRunner {
    static let claudeProcessNames: Set<String> = ["claude", "claude.exe"]
    static let hintPrefixes = ["GHOSTTY_", "VSCODE_", "ITERM_", "WEZTERM_", "TERM_SESSION_ID", "TERM_PROGRAM_VERSION"]

    /// Возвращает то, что нужно напечатать в stdout хука (JSON решения), либо nil — «без решения».
    /// Всё до получения «принято» укладывается в один общий срок `ackTimeout`.
    public static func run(
        stdin: Data,
        environment: [String: String],
        parentPid: Int32,
        socketPath: String,
        ackTimeout: Double = 0.3,
        decisionTimeout: Double = 600,
        makeRequestId: () -> String = { UUID().uuidString }
    ) -> Data? {
        let deadline = Date().addingTimeInterval(ackTimeout)
        guard let decoded = try? JSONDecoder().decode(HookEvent.self, from: stdin) else { return nil }
        let isRequest = decoded.hookEventName == "PermissionRequest"
        let event = decoded.slimmed()

        // Процесс сессии: CLAUDE_PID, иначе первый предок `claude` / `claude.exe`, иначе неизвестен (0).
        // Родитель хука «на всякий случай» не берём: это может быть оболочка-посредник, которая сразу завершится.
        let claudePid: Int32 = environment["CLAUDE_PID"].flatMap { Int32($0) }
            ?? ProcessProbe.ancestorPid(matching: { claudeProcessNames.contains($0) }, from: parentPid)
            ?? 0

        let unattended = environment["CLAUDE_CODE_SESSION_ATTENDED"] == "0"
            || (environment["CLAUDE_CODE_ENTRYPOINT"]?.hasPrefix("sdk") ?? false)

        let hints = environment
            .filter { key, _ in hintPrefixes.contains { key.hasPrefix($0) } }
            .mapValues { String($0.prefix(200)) }

        let message = BridgeMessage(
            requestId: makeRequestId(),
            event: event,
            pid: claudePid,
            processStartedAt: claudePid > 0 ? ProcessProbe.startTime(pid: claudePid) : nil,
            termProgram: environment["TERM_PROGRAM"],
            hostBundleId: environment["__CFBundleIdentifier"]
                ?? (environment["CLAUDE_CODE_ENTRYPOINT"] == "claude-vscode" ? "com.microsoft.VSCode" : nil),
            projectDir: environment["CLAUDE_PROJECT_DIR"],
            unattended: unattended,
            tty: claudePid > 0 ? ProcessProbe.ttyName(of: claudePid) : nil,
            hints: hints
        )

        guard let fd = SocketClient.connect(path: socketPath, timeout: deadline.timeIntervalSinceNow) else { return nil }
        defer { close(fd) }
        guard let payload = try? Wire.encode(message),
              SocketClient.writeAll(fd, payload, deadline: deadline) else { return nil }

        guard let ackLine = SocketClient.readLine(fd, timeout: max(0.01, deadline.timeIntervalSinceNow)),
              (try? Wire.decode(CoreReply.self, line: ackLine))?.kind == .ack else { return nil }

        guard isRequest else { return nil }

        guard let line = SocketClient.readLine(fd, timeout: decisionTimeout),
              let reply = try? Wire.decode(CoreReply.self, line: line),
              reply.kind == .decision, let behavior = reply.behavior else { return nil }

        var decision: [String: Any] = ["behavior": behavior]
        if behavior == "deny", let text = reply.message { decision["message"] = text }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

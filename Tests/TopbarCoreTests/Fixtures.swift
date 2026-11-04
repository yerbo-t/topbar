import Foundation
@testable import TopbarCore

enum Fx {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func msg(
        _ name: String,
        sid: String = "s1",
        req: String = UUID().uuidString,
        tool: String? = nil,
        input: JSONValue? = nil,
        source: String? = nil,
        interrupt: Bool? = nil,
        mode: String? = "default",
        pid: Int32 = 4242,
        started: Double? = 1000,
        toolUseId: String? = nil,
        agentType: String? = nil,
        root: String = "/work/topbar",
        term: String? = "ghostty",
        unattended: Bool = false
    ) -> BridgeMessage {
        BridgeMessage(
            requestId: req,
            event: HookEvent(name, sessionId: sid, cwd: root, source: source, toolName: tool,
                             toolInput: input, permissionMode: mode, isInterrupt: interrupt,
                             toolUseId: toolUseId, agentType: agentType),
            pid: pid, processStartedAt: started, termProgram: term, projectDir: root, unattended: unattended
        )
    }

    static func bash(_ cmd: String) -> JSONValue { .object(["command": .string(cmd)]) }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topbar-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Короткий путь сокета (лимит sun_path — 104 байта).
    static func socketPath() -> String { "/tmp/tb-\(UUID().uuidString.prefix(8)).sock" }
}

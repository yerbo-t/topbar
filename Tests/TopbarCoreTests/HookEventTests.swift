import XCTest
@testable import TopbarCore

final class HookEventTests: XCTestCase {
    func testDecodesPermissionRequestFromHookStdin() throws {
        let json = """
        {"session_id":"abc123","transcript_path":"/x.jsonl","cwd":"/Users/me/p","permission_mode":"default",
         "hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"rm -rf node_modules","description":"Remove"},
         "permission_suggestions":[{"type":"addRules"}],"agent_id":"sub1"}
        """
        let e = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.hookEventName, "PermissionRequest")
        XCTAssertEqual(e.sessionId, "abc123")
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolInput?["command"]?.stringValue, "rm -rf node_modules")
        XCTAssertEqual(e.agentId, "sub1")
        XCTAssertEqual(e.permissionMode, "default")
    }

    func testDecodesStopWithoutOptionalFields() throws {
        let json = #"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}"#
        let e = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.hookEventName, "Stop")
        XCTAssertNil(e.toolName)
    }

    func testRejectsEventWithoutSessionId() {
        let json = #"{"hook_event_name":"Stop"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)))
    }

    func testBridgeMessageRoundTripsThroughWire() throws {
        let m = Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("ls"))
        let data = try Wire.encode(m)
        XCTAssertEqual(data.last, 0x0A)
        let back = try Wire.decode(BridgeMessage.self, line: data.dropLast())
        XCTAssertEqual(back, m)
    }

    func testDecodesToolUseIdAndAgentType() throws {
        let json = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_use_id":"toolu_1","agent_type":"Explore"}"#
        let e = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.toolUseId, "toolu_1")
        XCTAssertEqual(e.agentType, "Explore")
    }

    func testSlimmedKeepsOnlyCommandAndPathsAndTruncates() {
        let big = String(repeating: "x", count: 5000)
        let input: JSONValue = .object(["command": .string(big), "content": .string(big), "file_path": .string("/a/b.txt")])
        let e = HookEvent("PreToolUse", sessionId: "s", toolName: "Write", toolInput: input).slimmed()
        guard case .object(let o)? = e.toolInput else { return XCTFail("нет ввода") }
        XCTAssertEqual(Set(o.keys), ["command", "file_path"])
        XCTAssertEqual(o["command"]?.stringValue?.count, 300)
    }

    func testSlimmedLeavesPermissionRequestUntouched() {
        let input: JSONValue = .object(["command": .string("ls"), "content": .string("keep me")])
        let e = HookEvent("PermissionRequest", sessionId: "s", toolName: "Write", toolInput: input)
        XCTAssertEqual(e.slimmed(), e)
    }
}

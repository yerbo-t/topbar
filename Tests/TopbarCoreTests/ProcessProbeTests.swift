import XCTest
@testable import TopbarCore

final class ProcessProbeTests: XCTestCase {
    func testOwnProcessIsAliveAndStartTimeIsRecent() {
        let me = getpid()
        let start = ProcessProbe.startTime(pid: me)
        XCTAssertNotNil(start)
        XCTAssertLessThan(Date().timeIntervalSince1970 - start!, 3600)
        XCTAssertTrue(ProcessProbe.isAlive(pid: me, startedAt: start))
    }

    func testWrongStartTimeMeansReusedPid() {
        let me = getpid()
        XCTAssertFalse(ProcessProbe.isAlive(pid: me, startedAt: 12345))
    }

    func testSpawnedProcessDiesAndIsDetected() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        let pid = p.processIdentifier
        let start = ProcessProbe.startTime(pid: pid)
        XCTAssertTrue(ProcessProbe.isAlive(pid: pid, startedAt: start))
        XCTAssertEqual(ProcessProbe.name(of: pid), "sleep")
        XCTAssertEqual(ProcessProbe.parentPid(of: pid), getpid())
        p.terminate()
        p.waitUntilExit()
        XCTAssertFalse(ProcessProbe.isAlive(pid: pid, startedAt: start))
    }

    func testAncestorLookup() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate() }
        XCTAssertEqual(ProcessProbe.ancestorPid(matching: { $0 == "sleep" }, from: p.processIdentifier), p.processIdentifier)
        XCTAssertNil(ProcessProbe.ancestorPid(matching: { $0 == "no-such-process-name" }, from: p.processIdentifier))
    }

    func testChildPidsListsSpawnedChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate() }
        XCTAssertTrue(ProcessProbe.childPids(of: getpid()).contains(p.processIdentifier))
        XCTAssertTrue(ProcessProbe.childPids(of: p.processIdentifier).isEmpty)
    }

    func testTtyNameDoesNotCrashForOwnProcess() {
        _ = ProcessProbe.ttyName(of: getpid()) // под тестами терминала может не быть
        XCTAssertNil(ProcessProbe.ttyName(of: 999_999))
    }
}

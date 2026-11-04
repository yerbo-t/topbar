import XCTest
@testable import TopbarCore

final class BranchReaderTests: XCTestCase {
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsBranchFromHeadAndFromSubfolder() throws {
        let root = Fx.tempDir()
        try write("ref: refs/heads/feat/discovery\n", to: root.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(BranchReader.branch(at: root.path), "feat/discovery")
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(BranchReader.branch(at: sub.path), "feat/discovery")
    }

    func testDetachedHeadGivesNil() throws {
        let root = Fx.tempDir()
        try write("3f2a1c0d9e8b7a6f5e4d3c2b1a0f9e8d7c6b5a49\n", to: root.appendingPathComponent(".git/HEAD"))
        XCTAssertNil(BranchReader.branch(at: root.path))
    }

    func testWorktreeGitFilePointsToGitdir() throws {
        let main = Fx.tempDir()
        let wtGitDir = main.appendingPathComponent(".git/worktrees/wt")
        try write("ref: refs/heads/fix/wt\n", to: wtGitDir.appendingPathComponent("HEAD"))
        let wt = Fx.tempDir()
        try write("gitdir: \(wtGitDir.path)\n", to: wt.appendingPathComponent(".git"))
        XCTAssertEqual(BranchReader.branch(at: wt.path), "fix/wt")
    }

    func testNoGitGivesNil() {
        XCTAssertNil(BranchReader.branch(at: Fx.tempDir().path))
    }
}

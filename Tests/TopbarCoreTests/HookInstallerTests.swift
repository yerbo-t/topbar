import XCTest
@testable import TopbarCore

final class HookInstallerTests: XCTestCase {
    let bridge = "/Users/me/Library/Application Support/topbar/bin/topbar-hook"

    func json(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testInstallIntoEmptyAddsAllEventsWithMarkerAndQuotedPath() throws {
        let out = try HookInstaller.install(into: nil, bridgePath: bridge)
        let hooks = json(out)["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.events.map(\.name)))
        let group = (hooks["PermissionRequest"] as! [[String: Any]])[0]
        let hook = (group["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(hook["command"] as? String, "'\(bridge)' # topbar-managed")
        XCTAssertEqual(hook["timeout"] as? Int, 600)
        XCTAssertTrue(HookInstaller.isInstalled(in: out))
    }

    func testInstallKeepsForeignSettingsAndHooks() throws {
        let existing = """
        {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
        """
        let out = try HookInstaller.install(into: Data(existing.utf8), bridgePath: bridge)
        let root = json(out)
        XCTAssertEqual(root["model"] as? String, "opus")
        let stop = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(((stop[0]["hooks"] as! [[String: Any]])[0])["command"] as? String, "say done")
    }

    func testInstallIsIdempotent() throws {
        let once = try HookInstaller.install(into: nil, bridgePath: bridge)
        let twice = try HookInstaller.install(into: once, bridgePath: bridge)
        XCTAssertEqual(once, twice)
    }

    func testRemoveRestoresForeignHooksOnly() throws {
        let existing = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
        """
        let installed = try HookInstaller.install(into: Data(existing.utf8), bridgePath: bridge)
        let removed = try HookInstaller.remove(from: installed)
        let hooks = json(removed)["hooks"] as! [String: Any]
        XCTAssertEqual(Array(hooks.keys), ["Stop"])
        XCTAssertFalse(HookInstaller.isInstalled(in: removed))
    }

    func testRemoveFromOnlyOurHooksDropsHooksKey() throws {
        let installed = try HookInstaller.install(into: nil, bridgePath: bridge)
        let removed = try HookInstaller.remove(from: installed)
        XCTAssertNil(json(removed)["hooks"])
    }

    func testDiffShowsOnlyAdditionsWhenFileIsAlreadyNormalized() throws {
        let old = try HookInstaller.remove(from: Data(#"{"model":"opus"}"#.utf8)) // нормализованный вид
        let new = try HookInstaller.install(into: old, bridgePath: bridge)
        let diff = HookInstaller.diff(old: old, new: new)
        XCTAssertTrue(diff.contains("+ "))
        XCTAssertFalse(diff.contains("- "))
        XCTAssertTrue(diff.contains("topbar-managed"))
        XCTAssertFalse(HookInstaller.willReformat(old))
    }

    func testDiffAndWarningShowReformattingOfHandWrittenFile() throws {
        let old = Data("{\"zeta\": 1,   \"alpha\": 2}".utf8) // порядок и пробелы будут изменены
        let new = try HookInstaller.install(into: old, bridgePath: bridge)
        XCTAssertTrue(HookInstaller.willReformat(old))
        XCTAssertTrue(HookInstaller.diff(old: old, new: new).contains("- {\"zeta\": 1,   \"alpha\": 2}"))
    }

    func testUnexpectedShapeIsRefusedInsteadOfOverwritten() {
        let weird = Data(#"{"hooks":{"Stop":"oops"}}"#.utf8)
        XCTAssertThrowsError(try HookInstaller.install(into: weird, bridgePath: bridge)) {
            XCTAssertEqual($0 as? HookInstaller.InstallError, .unexpectedShape("Stop"))
        }
        XCTAssertThrowsError(try HookInstaller.remove(from: weird))
        let weirdRoot = Data(#"{"hooks":[1]}"#.utf8)
        XCTAssertThrowsError(try HookInstaller.install(into: weirdRoot, bridgePath: bridge))
    }

    func testBridgePathsAreExtractedIncludingSpacesAndQuotes() throws {
        let tricky = "/Users/o'neil/Library/Application Support/topbar/bin/topbar-hook"
        let installed = try HookInstaller.install(into: nil, bridgePath: tricky)
        XCTAssertEqual(HookInstaller.bridgePaths(in: installed), [tricky])
        XCTAssertEqual(HookInstaller.bridgePaths(in: nil), [])
    }

    func testRejectsNonObjectSettings() {
        XCTAssertThrowsError(try HookInstaller.install(into: Data("[1,2]".utf8), bridgePath: bridge))
    }
}

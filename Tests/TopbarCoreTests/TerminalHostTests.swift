import XCTest
@testable import TopbarCore

final class TerminalHostTests: XCTestCase {
    func testKnownBundleIdsGiveNames() {
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "com.apple.Terminal"), "Terminal")
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "com.googlecode.iterm2"), "iTerm2")
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "dev.warp.Warp-Stable"), "Warp")
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "com.github.wez.wezterm"), "WezTerm")
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "net.kovidgoyal.kitty"), "kitty")
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "org.alacritty"), "Alacritty")
        XCTAssertEqual(TerminalHost.name(termProgram: nil, bundleId: "com.todesktop.230313mzl4w4u92"), "Cursor")
    }

    func testBundleIdWinsOverTermProgram() {
        // Cursor и другие форки VS Code тоже ставят TERM_PROGRAM=vscode; tmux ставит TERM_PROGRAM=tmux.
        XCTAssertEqual(TerminalHost.name(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92"), "Cursor")
        XCTAssertEqual(TerminalHost.name(termProgram: "tmux", bundleId: "com.mitchellh.ghostty"), "Ghostty")
        XCTAssertEqual(TerminalHost.bundleId(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92"), "com.todesktop.230313mzl4w4u92")
    }

    func testUnknownBundleIdHasNoNameButIsKept() {
        // Имя такому приложению даёт слой с окнами (по идентификатору), ядро его не знает.
        XCTAssertNil(TerminalHost.name(termProgram: "vscode", bundleId: "com.example.NewTerminal"))
        XCTAssertEqual(TerminalHost.bundleId(termProgram: nil, bundleId: "com.example.NewTerminal"), "com.example.NewTerminal")
    }

    func testTermProgramIsUsedWithoutBundleId() {
        XCTAssertEqual(TerminalHost.name(termProgram: "ghostty", bundleId: nil), "Ghostty")
        XCTAssertEqual(TerminalHost.name(termProgram: "Apple_Terminal", bundleId: nil), "Terminal")
        XCTAssertEqual(TerminalHost.name(termProgram: "iTerm.app", bundleId: nil), "iTerm2")
        XCTAssertEqual(TerminalHost.name(termProgram: "WarpTerminal", bundleId: nil), "Warp")
        XCTAssertEqual(TerminalHost.name(termProgram: "WezTerm", bundleId: nil), "WezTerm")
        XCTAssertEqual(TerminalHost.name(termProgram: "vscode", bundleId: nil), "VS Code")
        XCTAssertEqual(TerminalHost.bundleId(termProgram: "Apple_Terminal", bundleId: nil), "com.apple.Terminal")
        XCTAssertEqual(TerminalHost.bundleId(termProgram: "iTerm.app", bundleId: nil), "com.googlecode.iterm2")
    }

    func testUnknownTermProgramKeepsRawNameWithoutBundle() {
        XCTAssertEqual(TerminalHost.name(termProgram: "tmux", bundleId: nil), "tmux")
        XCTAssertNil(TerminalHost.bundleId(termProgram: "tmux", bundleId: nil))
        XCTAssertNil(TerminalHost.name(termProgram: nil, bundleId: nil))
        XCTAssertNil(TerminalHost.bundleId(termProgram: nil, bundleId: nil))
    }

    func testEditorsAreRecognisedByBundleId() {
        XCTAssertTrue(TerminalHost.isEditor(bundleId: "com.microsoft.VSCode"))
        XCTAssertTrue(TerminalHost.isEditor(bundleId: "com.microsoft.VSCodeInsiders"))
        XCTAssertTrue(TerminalHost.isEditor(bundleId: "com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(TerminalHost.isEditor(bundleId: "com.apple.Terminal"))
        XCTAssertFalse(TerminalHost.isEditor(bundleId: nil))
    }

    func testLegacyHostNameStillMapsToBundleId() {
        XCTAssertEqual(TerminalHost.bundleId(forName: "Ghostty"), "com.mitchellh.ghostty")
        XCTAssertEqual(TerminalHost.bundleId(forName: "VS Code"), "com.microsoft.VSCode")
        XCTAssertEqual(TerminalHost.bundleId(forName: "iTerm2"), "com.googlecode.iterm2")
        XCTAssertNil(TerminalHost.bundleId(forName: "tmux"))
    }
}

import XCTest
@testable import TopbarCore

/// Подписи сессий (имя из журнала, проект, ветка) и вопрос карточки.
final class SessionLabelTests: XCTestCase {
    let now = Fx.t0

    private func msg(_ name: String, sid: String = "s1", transcript: String? = "/t/s1.jsonl", tool: String? = nil,
                     input: JSONValue? = nil, pid: Int32 = 4242) -> BridgeMessage {
        var m = Fx.msg(name, sid: sid, tool: tool, input: input, pid: pid)
        m.event.transcriptPath = transcript
        return m
    }

    // MARK: журнал сессии

    private func write(_ lines: [String], to url: URL, append: Bool = false) throws {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
    }

    func testReaderPrefersOwnerNameOverAiTitleAndFollowsAppends() throws {
        let url = Fx.tempDir().appendingPathComponent("s.jsonl")
        try write([
            #"{"type":"user","message":{"content":"text with \"type\":\"custom-title\" inside"}}"#,
            #"{"type":"ai-title","aiTitle":"Fix login redirect","sessionId":"s"}"#,
        ], to: url)
        let reader = SessionNameReader()
        XCTAssertEqual(reader.name(at: url.path), "Fix login redirect", "экранированный текст в сообщении — не имя")

        try write([#"{"type":"custom-title","customTitle":"design","sessionId":"s"}"#], to: url, append: true)
        XCTAssertEqual(reader.name(at: url.path), "design", "имя владельца главнее придуманного")

        try write([#"{"type":"ai-title","aiTitle":"Another","sessionId":"s"}"#], to: url, append: true)
        XCTAssertEqual(reader.name(at: url.path), "design", "придуманное позже не перебивает имя владельца")
    }

    func testReaderWaitsForUnfinishedLineAndReadsOnlyTheTail() throws {
        let url = Fx.tempDir().appendingPathComponent("s.jsonl")
        let filler = String(repeating: "x", count: 300)
        try write([#"{"type":"ai-title","aiTitle":"Old","sessionId":"s"}"#] + Array(repeating: #"{"type":"user","t":"\#(filler)"}"#, count: 20), to: url)
        let reader = SessionNameReader(tailLimit: 1000)
        XCTAssertNil(reader.name(at: url.path), "имя далеко от хвоста — не читаем весь журнал")

        // Строка дописывается в два приёма: половина строки именем не считается.
        let line = #"{"type":"ai-title","aiTitle":"New","sessionId":"s"}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.prefix(20).utf8))
        XCTAssertNil(reader.name(at: url.path))
        try handle.write(contentsOf: Data((line.dropFirst(20) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(reader.name(at: url.path), "New")
    }

    func testReaderIgnoresOtherFilesAndMissingOnes() {
        let reader = SessionNameReader()
        XCTAssertNil(reader.name(at: "/etc/hosts"))
        XCTAssertNil(reader.name(at: "/nonexistent/s.jsonl"))
    }

    // MARK: хранилище

    func testFirstEventOfUnknownSessionReadsBranchAndName() {
        var store = SessionStore(branchProvider: { _ in "feat/x" }, nameProvider: { $0 == "/t/s1.jsonl" ? "design" : nil })
        // topbar перезапущен посреди сессии: первое, что он видит, — запрос разрешения.
        store.apply(msg("PermissionRequest", tool: "Bash", input: Fx.bash("ls")), now: now)
        XCTAssertEqual(store.sessions["s1"]?.branch, "feat/x")
        XCTAssertEqual(store.sessions["s1"]?.name, "design")
    }

    func testRenameIsPickedUpByTheNextPermissionRequest() {
        var current = "Начало работы"
        var store = SessionStore(nameProvider: { _ in current })
        store.apply(msg("UserPromptSubmit"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.name, "Начало работы")
        current = "backend"
        store.apply(msg("PermissionRequest", tool: "Bash", input: Fx.bash("ls")), now: now)
        XCTAssertEqual(store.sessions["s1"]?.name, "backend")
    }

    func testLabelsShowSessionNameOverProjectAndSuffixOnlyTrueDuplicates() {
        var names = ["a": "design", "b": "backend"]
        var store = SessionStore(branchProvider: { _ in "main" }, nameProvider: { path in names[(path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")] })
        store.apply(msg("UserPromptSubmit", sid: "a", transcript: "/t/a.jsonl", pid: 1), now: now)
        store.apply(msg("UserPromptSubmit", sid: "b", transcript: "/t/b.jsonl", pid: 2), now: now.addingTimeInterval(1))
        store.apply(msg("UserPromptSubmit", sid: "c", transcript: "/t/c.jsonl", pid: 3), now: now.addingTimeInterval(2))
        store.apply(msg("UserPromptSubmit", sid: "d", transcript: "/t/d.jsonl", pid: 4), now: now.addingTimeInterval(3))
        let labels = SessionStore.displayLabels(store.snapshot())
        XCTAssertEqual(labels["a"], SessionLabel(title: "design", project: "topbar", branch: "main"))
        XCTAssertEqual(labels["b"], SessionLabel(title: "backend", project: "topbar", branch: "main"))
        XCTAssertEqual(labels["c"], SessionLabel(title: "topbar", project: nil, branch: "main"), "без имени крупно — проект")
        XCTAssertEqual(labels["d"]?.title, "topbar #2")
        names["b"] = "design"
        store.apply(msg("UserPromptSubmit", sid: "b", transcript: "/t/b.jsonl", pid: 2), now: now.addingTimeInterval(4))
        XCTAssertEqual(SessionStore.displayLabels(store.snapshot())["b"]?.title, "design #2")
    }

    func testNameChangeIsVisible() {
        var a = Session(sessionId: "a", projectRoot: "/w", project: "w", branch: nil, status: .idle, currentAction: "", pid: 1,
                        hints: [:], firstSeenAt: now, lastEventAt: now, running: [], unseenDone: false, queue: [])
        let b = a
        a.name = "design"
        XCTAssertFalse(a.sameForDisplay(as: b))
    }

    // MARK: вопрос карточки

    func testQuestionNamesTheActionNotTheTool() {
        let q = ActionDescriber.question
        XCTAssertEqual(q("Bash", Fx.bash("ls")), "Разрешить выполнить команду?")
        XCTAssertEqual(q("Edit", .object(["file_path": .string("/w/Sources/App.swift")])), "Разрешить изменить файл App.swift?")
        XCTAssertEqual(q("Write", .object(["file_path": .string("/w/a.md")])), "Разрешить записать файл a.md?")
        XCTAssertEqual(q("WebFetch", .object(["url": .string("https://github.com/x/y")])), "Разрешить открыть страницу github.com?")
        XCTAssertEqual(q("mcp__claude-in-chrome__navigate", nil), "Разрешить navigate из claude-in-chrome?")
        XCTAssertEqual(q("Frobnicate", nil), "Разрешить инструмент Frobnicate?")
    }

    func testPurposeIsWhatClaudeSaidAboutTheCommand() {
        let input: JSONValue = .object(["command": .string("swift build"), "description": .string("Build the package\nsecond")])
        XCTAssertEqual(ActionDescriber.purpose(toolName: "Bash", input: input), "Build the package")
        XCTAssertNil(ActionDescriber.purpose(toolName: "Bash", input: Fx.bash("ls")))
        let home = NSHomeDirectory()
        XCTAssertEqual(ActionDescriber.purpose(toolName: "Edit", input: .object(["file_path": .string(home + "/p/a.swift")])), "~/p/a.swift")
    }

    func testPermissionRequestCarriesQuestionAndPurpose() {
        var store = SessionStore()
        let input: JSONValue = .object(["command": .string("rm -rf build"), "description": .string("Clean build folder")])
        store.apply(msg("PermissionRequest", tool: "Bash", input: input), now: now)
        let request = store.sessions["s1"]?.queue.first
        XCTAssertEqual(request?.question, "Разрешить выполнить команду?")
        XCTAssertEqual(request?.purpose, "Clean build folder")
        XCTAssertEqual(request?.detail, "rm -rf build", "сама команда — целиком и без изменений")
    }

    func testEditIsShownAsChangeNotJson() {
        let edit: JSONValue = .object(["file_path": .string("/w/a.swift"), "old_string": .string("let a = 1\nlet b = 2"), "new_string": .string("let a = 3")])
        XCTAssertEqual(ActionDescriber.detail(toolName: "Edit", input: edit), "- let a = 1\n- let b = 2\n+ let a = 3")
        let multi: JSONValue = .object(["file_path": .string("/w/a.swift"), "edits": .array([
            .object(["old_string": .string("x"), "new_string": .string("y"), "replace_all": .bool(true)]),
            .object(["old_string": .string("p"), "new_string": .string("")]),
        ])])
        XCTAssertEqual(ActionDescriber.detail(toolName: "MultiEdit", input: multi), "- x\n+ y\n(во всех местах файла)\n\n- p")
        XCTAssertEqual(ActionDescriber.detail(toolName: "Write", input: .object(["file_path": .string("/w/a.md"), "content": .string("# Hi")])), "# Hi")
    }

    func testHookEventDecodesTranscriptPath() throws {
        let json = #"{"session_id":"abc","transcript_path":"/x/abc.jsonl","hook_event_name":"Stop"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.transcriptPath, "/x/abc.jsonl")
    }
}

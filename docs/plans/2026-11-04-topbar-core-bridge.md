# topbar: ядро и мост хуков — план реализации (часть 1 из 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Рабочая «невидимая» половина topbar: мост хука + ядро сессий Claude Code (сокет, автомат статусов, ответы на запросы разрешений, проверка живости, установка хуков), проверенная юнит-тестами и на настоящих сессиях в Ghostty и VS Code через консоль разработчика.

**Architecture:** Swift Package из трёх целей. `TopbarCore` (библиотека) — вся логика: чистый автомат статусов `SessionStore`, Unix-сокет с кадрированием «одна строка JSON», `BridgeRunner` (логика моста), `SessionHub` (склейка сокета, автомата и проверки живости), `HookInstaller`. `topbar-hook` — крошечный исполняемый файл-мост, который Claude Code запускает по событиям. `topbar-dev` — консоль разработчика вместо окна острова. Данные идут Claude Code → мост → ядро → (позже) оверлей; назад идёт только решение владельца.

**Tech Stack:** Swift 6.4 (режим языка 5, `swift-tools-version: 5.10`), SwiftPM, XCTest, Foundation + Darwin (POSIX-сокеты, `sysctl`, `poll`), macOS 14+.

**Спека:** `docs/specs/2026-11-03-topbar-mvp.md` (утверждена 2026-11-04).

---

## Границы этого плана

Часть 1 (этот файл) даёт всё, что не требует окна. Часть 2 (оверлей на вырезе, карточка, иконка в строке меню, звук, переход к сессии, определение «владелец смотрит», запуск при входе, сон/смена экрана, сборка `.app`) пишется отдельным планом **после** того, как часть 1 пройдёт проверку на настоящих сессиях: оверлею нужны подтверждённые факты (см. задачу 9), а не догадки. Это делит работу на два самостоятельно проверяемых куска, как требует скилл.

**Отличия от спеки, которые план вводит осознанно:**
- Событие `Notification` не подписываем: в переходах оно не участвует, а каждая подписка — лишний запуск процесса.
- Тайм-аут хуков, кроме `PermissionRequest`, — 5 с (мост сам выходит за 0,3 с); для `PermissionRequest` — 600 с (потолок на случай, если ядро не ответит).
- Признак «сессия без терминала» — недокументированные переменные окружения хука (`CLAUDE_CODE_SESSION_ATTENDED=0` или `CLAUDE_CODE_ENTRYPOINT=sdk…`), увиденные в Claude Code 2.1.317 при `claude -p`. На интерактивной сессии их значения проверяются в задаче 9; если они окажутся другими, правится одна функция в `BridgeRunner`.
- Номер процесса сессии берётся из `CLAUDE_PID` (тоже недокументирован, виден в окружении хука), запасной путь — подъём по дереву процессов до `claude`.
- Хук не несёт `tool_use_id`, поэтому `PostToolUse` закрывает первый открытый запрос **с тем же именем инструмента**. При параллельных вызовах одного инструмента возможна путаница очерёдности; для MVP принято.

**Что в этом плане сознательно не делается:** окно острова, звук, меню, определение «смотрит на сессию» (`cardPolicy` по умолчанию показывает всегда), запуск при входе, переход к окну сессии. Всё это — часть 2.

## Структура файлов

```
Package.swift
.gitignore                                  (дописать .build/)
Sources/TopbarCore/
  JSONValue.swift       произвольный JSON для tool_input
  HookEvent.swift       событие хука (snake_case из stdin)
  Wire.swift            BridgeMessage, CoreReply, кадрирование строк
  Paths.swift           каталог данных, путь сокета, путь моста
  Session.swift         Session, PermissionRequest, Summary, PermissionPolicy, ActionDescriber
  SessionStore.swift    автомат статусов (чистая логика)
  BranchReader.swift    ветка из .git/HEAD (включая worktree)
  ProcessProbe.swift    время старта, родитель, имя, живость процесса
  Sockets.swift         SocketClient (мост) и SocketServer (ядро)
  BridgeRunner.swift    логика моста
  HookInstaller.swift   вписать/убрать хуки в settings.json
  SessionHub.swift      склейка: сокет + автомат + живость + решения
Sources/topbar-hook/main.swift              мост хука
Sources/topbar-dev/main.swift               консоль разработчика
Tests/TopbarCoreTests/
  Fixtures.swift, HookEventTests.swift, SessionStoreTests.swift, BranchReaderTests.swift,
  ProcessProbeTests.swift, BridgeSocketTests.swift, HookInstallerTests.swift, SessionHubTests.swift
```

Все команды выполняются из корня репозитория `/Users/yer6o/Documents/VSCODE/projects/topbar`. Работа идёт в ветке `feat/core-bridge` (не в `main`).

---

### Task 0: Ветка и проверка инструментов

**Files:** нет

- [ ] **Step 1: Создать рабочую ветку**

Run: `git switch -c feat/core-bridge`
Expected: `Switched to a new branch 'feat/core-bridge'` (от `feat/discovery`, где лежат спека и этот план).

- [ ] **Step 2: Проверить, что Xcode и Swift согласованы**

Run: `xcodebuild -version && swift --version && swift package --version`
Expected: `Xcode 27.x`, `Apple Swift version 6.4.x`, `Swift Package Manager - Swift 6.4.x`. Если вместо этого `You have not agreed to the Xcode license` — попросить владельца выполнить в обычном терминале `sudo xcodebuild -license accept`.

---

### Task 1: Каркас пакета, формат событий и протокол

**Files:**
- Create: `Package.swift`, `Sources/TopbarCore/JSONValue.swift`, `HookEvent.swift`, `Wire.swift`, `Paths.swift`
- Create (заглушки): `Sources/topbar-hook/main.swift`, `Sources/topbar-dev/main.swift`
- Create (тесты): `Tests/TopbarCoreTests/Fixtures.swift`, `HookEventTests.swift`
- Modify: `.gitignore`

- [ ] **Step 1: Дописать в `.gitignore`**

Run: `printf '\n# SwiftPM\n.build/\n.swiftpm/\n' >> .gitignore && tail -4 .gitignore`
Expected: последние строки — `# SwiftPM`, `.build/`, `.swiftpm/`.

- [ ] **Step 2: Создать манифест и заглушки исполняемых целей**

**Create:** `Package.swift`

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "topbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopbarCore", targets: ["TopbarCore"]),
        .executable(name: "topbar-hook", targets: ["topbar-hook"]),
        .executable(name: "topbar-dev", targets: ["topbar-dev"]),
    ],
    targets: [
        .target(name: "TopbarCore"),
        .executableTarget(name: "topbar-hook", dependencies: ["TopbarCore"]),
        .executableTarget(name: "topbar-dev", dependencies: ["TopbarCore"]),
        .testTarget(name: "TopbarCoreTests", dependencies: ["TopbarCore"]),
    ]
)
```

**Create:** `Sources/topbar-hook/main.swift`

```swift
// Временная заглушка; настоящий мост появится в задаче 8.
print("topbar-hook: заглушка")
```

**Create:** `Sources/topbar-dev/main.swift`

```swift
// Временная заглушка; настоящая консоль появится в задаче 8.
print("topbar-dev: заглушка")
```

- [ ] **Step 3: Написать тесты (они не соберутся: типов ещё нет)**

**Create:** `Tests/TopbarCoreTests/Fixtures.swift`

```swift
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
        root: String = "/work/topbar",
        term: String? = "ghostty",
        unattended: Bool = false
    ) -> BridgeMessage {
        BridgeMessage(
            requestId: req,
            event: HookEvent(name, sessionId: sid, cwd: root, source: source, toolName: tool,
                             toolInput: input, permissionMode: mode, isInterrupt: interrupt),
            pid: pid, processStartedAt: 1000, termProgram: term, projectDir: root, unattended: unattended
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
```

**Create:** `Tests/TopbarCoreTests/HookEventTests.swift`

```swift
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
}
```

- [ ] **Step 4: Убедиться, что сборка тестов падает**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `error: … target 'TopbarCore' referenced in product 'TopbarCore' is empty` (в цели пока нет исходников).

- [ ] **Step 5: Реализовать типы**

**Create:** `Sources/TopbarCore/JSONValue.swift`

```swift
import Foundation

/// Произвольный JSON (нужен для `tool_input`, у которого нет фиксированной схемы).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
```

**Create:** `Sources/TopbarCore/HookEvent.swift`

```swift
import Foundation

/// Событие хука Claude Code, как оно приходит в stdin хука (snake_case).
public struct HookEvent: Codable, Equatable, Sendable {
    public var hookEventName: String
    public var sessionId: String
    public var cwd: String?
    public var source: String?
    public var reason: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var permissionMode: String?
    public var agentId: String?
    public var isInterrupt: Bool?
    public var notificationType: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd, source, reason
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionMode = "permission_mode"
        case agentId = "agent_id"
        case isInterrupt = "is_interrupt"
        case notificationType = "notification_type"
    }

    public init(
        _ name: String,
        sessionId: String,
        cwd: String? = nil,
        source: String? = nil,
        reason: String? = nil,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        permissionMode: String? = nil,
        agentId: String? = nil,
        isInterrupt: Bool? = nil,
        notificationType: String? = nil
    ) {
        self.hookEventName = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.source = source
        self.reason = reason
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionMode = permissionMode
        self.agentId = agentId
        self.isInterrupt = isInterrupt
        self.notificationType = notificationType
    }
}
```

**Create:** `Sources/TopbarCore/Wire.swift`

```swift
import Foundation

/// То, что мост передаёт ядру: событие хука плюс сведения о процессе и окружении.
public struct BridgeMessage: Codable, Equatable, Sendable {
    public var requestId: String
    public var event: HookEvent
    public var pid: Int32
    public var processStartedAt: Double?
    public var termProgram: String?
    public var projectDir: String?
    /// Сессия без терминала (`claude -p`, SDK): карточки ей не нужны.
    public var unattended: Bool

    public init(
        requestId: String,
        event: HookEvent,
        pid: Int32,
        processStartedAt: Double? = nil,
        termProgram: String? = nil,
        projectDir: String? = nil,
        unattended: Bool = false
    ) {
        self.requestId = requestId
        self.event = event
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.termProgram = termProgram
        self.projectDir = projectDir
        self.unattended = unattended
    }
}

/// Ответ ядра мосту. `ack` — «принято»; `decision` — решение владельца; `none` — «без решения».
public struct CoreReply: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ack, decision, none }
    public var kind: Kind
    public var behavior: String?
    public var message: String?

    public init(kind: Kind, behavior: String? = nil, message: String? = nil) {
        self.kind = kind
        self.behavior = behavior
        self.message = message
    }

    public static let ack = CoreReply(kind: .ack)
    public static let none = CoreReply(kind: .none)
    public static func allow() -> CoreReply { CoreReply(kind: .decision, behavior: "allow") }
    public static func deny(_ message: String = "Отклонено в topbar") -> CoreReply {
        CoreReply(kind: .decision, behavior: "deny", message: message)
    }
}

/// Кадрирование: одна строка JSON на сообщение.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
```

**Create:** `Sources/TopbarCore/Paths.swift`

```swift
import Foundation

public enum Paths {
    public static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/topbar" }
    public static var socketPath: String { supportDir + "/hook.sock" }
    /// Стабильный путь моста: хуки в настройках Claude Code ссылаются именно на него.
    public static var bridgeInstallPath: String { supportDir + "/bin/topbar-hook" }
}
```

- [ ] **Step 6: Прогнать тесты**

Run: `swift test --filter HookEventTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "feat(core): package skeleton, hook event and wire types"
```

---

### Task 2: Модель сессий и автомат статусов

**Files:**
- Create: `Sources/TopbarCore/Session.swift`, `Sources/TopbarCore/SessionStore.swift`
- Test: `Tests/TopbarCoreTests/SessionStoreTests.swift`

Автомат — чистая логика: время и ветку ему подают снаружи, поэтому он целиком проверяется без процессов и сокетов. Правила взяты из раздела «Ядро сессий» спеки; ключевые решения закреплены тестами: `compact` не сбрасывает статус, прерывание и `StopFailure` не оставляют сессию в «работает», `PostToolUse` после `Stop` не оживляет сессию, «тишина» не трогает сессию с выполняющимся инструментом.

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/SessionStoreTests.swift`

```swift
import XCTest
@testable import TopbarCore

final class SessionStoreTests: XCTestCase {
    var store = SessionStore(branchProvider: { _ in "feat/x" })
    let now = Fx.t0

    func status(_ sid: String = "s1") -> SessionStatus? { store.sessions[sid]?.status }

    func testLifecycleStartPromptToolStop() {
        store.apply(Fx.msg("SessionStart", source: "startup"), now: now)
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.project, "topbar")
        XCTAssertEqual(store.sessions["s1"]?.branch, "feat/x")
        XCTAssertEqual(store.sessions["s1"]?.hostApp, "Ghostty")

        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        XCTAssertEqual(status(), .working)

        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("pnpm test\nsecond line")), now: now)
        XCTAssertEqual(store.sessions["s1"]?.currentAction, "Bash: pnpm test")
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, true)

        let effects = store.apply(Fx.msg("Stop"), now: now)
        XCTAssertEqual(status(), .done)
        XCTAssertEqual(store.sessions["s1"]?.unseenDone, true)
        XCTAssertEqual(effects, [.sessionBecameDone(sessionId: "s1")])
    }

    func testPermissionRequestOpensAndPostToolUseClosesIt() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("mkdir x")), now: now)
        let opened = store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("mkdir x")), now: now)
        XCTAssertEqual(status(), .waitingPermission)
        guard case .requestOpened(let r) = opened.first else { return XCTFail("нет requestOpened") }
        XCTAssertEqual(r.requestId, "r1")
        XCTAssertEqual(r.summary, "Bash: mkdir x")

        let closed = store.apply(Fx.msg("PostToolUse", tool: "Bash"), now: now)
        XCTAssertEqual(closed, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(status(), .working)
        XCTAssertTrue(store.sessions["s1"]!.queue.isEmpty)
    }

    func testTwoRequestsKeepSessionWaitingUntilBothClosed() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("a")), now: now)
        store.apply(Fx.msg("PermissionRequest", req: "r2", tool: "Write"), now: now)
        store.apply(Fx.msg("PostToolUse", tool: "Bash"), now: now)
        XCTAssertEqual(status(), .waitingPermission)
        XCTAssertEqual(store.sessions["s1"]?.queue.map(\.requestId), ["r2"])
        store.apply(Fx.msg("PostToolUse", tool: "Write"), now: now)
        XCTAssertEqual(status(), .working)
    }

    func testResolveFromIslandRemovesRequestAndReturnsToWorking() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        XCTAssertTrue(store.resolve(requestId: "r1"))
        XCTAssertEqual(status(), .working)
        XCTAssertFalse(store.resolve(requestId: "r1"))
    }

    func testInterruptReturnsToIdleAndClosesRequests() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        let effects = store.apply(Fx.msg("PostToolUseFailure", tool: "Bash", interrupt: true), now: now)
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(store.sessions["s1"]?.currentAction, "Прервано")
    }

    func testStopFailureGoesIdleWithErrorNote() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("StopFailure"), now: now)
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.currentAction, "Ошибка API")
    }

    func testCompactDoesNotResetWorkingButClearDoes() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("SessionStart", source: "compact"), now: now)
        XCTAssertEqual(status(), .working)
        store.apply(Fx.msg("SessionStart", source: "clear"), now: now)
        XCTAssertEqual(status(), .idle)
    }

    func testSessionEndRemovesSessionAndClosesRequests() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        let effects = store.apply(Fx.msg("SessionEnd"), now: now)
        XCTAssertNil(store.sessions["s1"])
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1"), .sessionRemoved(sessionId: "s1")])
    }

    func testUnknownSessionFirstEventCreatesItWithMatchingStatus() {
        store.apply(Fx.msg("PermissionRequest", sid: "late", req: "r9", tool: "Bash"), now: now)
        XCTAssertEqual(status("late"), .waitingPermission)
        store.apply(Fx.msg("PostToolUse", sid: "other", tool: "Bash"), now: now)
        XCTAssertEqual(status("other"), .working)
        store.apply(Fx.msg("Stop", sid: "third"), now: now)
        XCTAssertEqual(status("third"), .done)
    }

    func testPostToolUseAfterStopDoesNotReviveSession() {
        store.apply(Fx.msg("Stop"), now: now)
        store.apply(Fx.msg("PostToolUse", tool: "Bash"), now: now)
        XCTAssertEqual(status(), .done)
    }

    func testSweepQuietOnlyWhenNoToolRunning() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        let later = now.addingTimeInterval(601)
        XCTAssertEqual(store.sweepQuiet(now: later), ["s1"])
        XCTAssertEqual(status(), .idle)

        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("sleep 900")), now: now)
        XCTAssertEqual(store.sweepQuiet(now: later), [])
        XCTAssertEqual(status(), .working)
    }

    func testMarkViewedClearsDoneMark() {
        store.apply(Fx.msg("Stop"), now: now)
        store.markViewed(sessionId: "s1")
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.unseenDone, false)
    }

    func testSummaryCountsAndTopStatusPriority() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "a"), now: now)
        store.apply(Fx.msg("Stop", sid: "b"), now: now)
        store.apply(Fx.msg("SessionStart", sid: "c", source: "startup"), now: now)
        XCTAssertEqual(store.summary(), Summary(waiting: 0, working: 1, done: 1, idle: 1, top: .done))
        store.apply(Fx.msg("PermissionRequest", sid: "a", req: "r", tool: "Bash"), now: now)
        XCTAssertEqual(store.summary().top, .waitingPermission)
        XCTAssertEqual(store.snapshot().first?.sessionId, "a")
    }

    func testDuplicateTitlesGetSuffix() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "a"), now: now)
        store.apply(Fx.msg("UserPromptSubmit", sid: "b"), now: now.addingTimeInterval(5))
        let titles = SessionStore.displayTitles(store.snapshot())
        XCTAssertEqual(titles["a"], "topbar · feat/x")
        XCTAssertEqual(titles["b"], "topbar · feat/x #2")
    }

    func testRemoveWithoutSessionEnd() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash"), now: now)
        let effects = store.remove(sessionId: "s1")
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1"), .sessionRemoved(sessionId: "s1")])
    }

    func testPolicyDoesNotInterceptQuestionTools() {
        XCTAssertFalse(PermissionPolicy.intercepts(toolName: "AskUserQuestion"))
        XCTAssertFalse(PermissionPolicy.intercepts(toolName: "ExitPlanMode"))
        XCTAssertTrue(PermissionPolicy.intercepts(toolName: "Bash"))
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'SessionStore' in scope`.

- [ ] **Step 3: Реализовать модель и автомат**

**Create:** `Sources/TopbarCore/Session.swift`

```swift
import Foundation

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case idle, working, waitingPermission, done

    /// Чем меньше, тем срочнее: ждёт разрешения → готова → работает → простаивает.
    public var urgency: Int {
        switch self {
        case .waitingPermission: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        }
    }
}

public struct PermissionRequest: Equatable, Sendable {
    public let requestId: String
    public let sessionId: String
    public let toolName: String
    /// Короткое описание того, что просит инструмент (для карточки).
    public let summary: String
    public let agentId: String?
    public let receivedAt: Date
}

public struct Session: Equatable, Sendable {
    public var sessionId: String
    public var projectRoot: String
    public var project: String
    public var branch: String?
    public var status: SessionStatus
    public var currentAction: String
    public var pid: Int32
    public var processStartedAt: Double?
    public var hostApp: String?
    public var permissionMode: String?
    public var firstSeenAt: Date
    public var lastEventAt: Date
    public var toolRunning: Bool
    public var unseenDone: Bool
    public var queue: [PermissionRequest]
}

public struct Summary: Equatable, Sendable {
    public var waiting = 0
    public var working = 0
    public var done = 0
    public var idle = 0
    /// Самый срочный статус из имеющихся (по нему красится остров).
    public var top: SessionStatus?
}

/// Какие инструменты остров не перехватывает: кнопки «разрешить/отклонить» для них бессмысленны.
public enum PermissionPolicy {
    public static let passthroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public static func intercepts(toolName: String?) -> Bool {
        guard let toolName else { return true }
        return !passthroughTools.contains(toolName)
    }
}

public enum ActionDescriber {
    public static func describe(toolName: String?, input: JSONValue?) -> String {
        guard let toolName else { return "" }
        switch toolName {
        case "Bash":
            let cmd = input?["command"]?.stringValue ?? ""
            return "Bash: " + oneLine(cmd, limit: 80)
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
            let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue ?? ""
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? toolName : "\(toolName) \(name)"
        default:
            return toolName
        }
    }

    public static func oneLine(_ text: String, limit: Int) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }
}
```

**Create:** `Sources/TopbarCore/SessionStore.swift`

```swift
import Foundation

public enum StoreEffect: Equatable, Sendable {
    case requestOpened(PermissionRequest)
    case requestClosed(requestId: String)
    case sessionBecameDone(sessionId: String)
    case sessionRemoved(sessionId: String)
}

/// Автомат статусов сессий. Чистая логика без ввода-вывода: время и ветку подают снаружи.
public struct SessionStore {
    public private(set) var sessions: [String: Session] = [:]
    private let branchProvider: (String) -> String?

    public init(branchProvider: @escaping (String) -> String? = { _ in nil }) {
        self.branchProvider = branchProvider
    }

    // MARK: события хуков

    @discardableResult
    public mutating func apply(_ msg: BridgeMessage, now: Date) -> [StoreEffect] {
        let ev = msg.event
        var effects: [StoreEffect] = []
        let existing = sessions[ev.sessionId]
        let isNew = existing == nil
        var s = existing ?? makeSession(msg, now: now)

        s.pid = msg.pid
        s.processStartedAt = msg.processStartedAt
        if let host = Self.hostName(msg.termProgram) { s.hostApp = host }
        if let mode = ev.permissionMode { s.permissionMode = mode }
        s.lastEventAt = now

        switch ev.hookEventName {
        case "SessionStart":
            if !isNew && ev.source != "compact" {
                effects += closeAll(&s)
                s.status = .idle
                s.toolRunning = false
                s.currentAction = ""
            }
            refreshBranch(&s)

        case "UserPromptSubmit":
            effects += closeAll(&s)
            s.status = .working
            s.unseenDone = false
            s.toolRunning = false
            s.currentAction = "Думает"
            refreshBranch(&s)

        case "PreToolUse":
            s.toolRunning = true
            s.currentAction = ActionDescriber.describe(toolName: ev.toolName, input: ev.toolInput)
            if s.queue.isEmpty { s.status = .working }

        case "PermissionRequest":
            let request = PermissionRequest(
                requestId: msg.requestId,
                sessionId: ev.sessionId,
                toolName: ev.toolName ?? "?",
                summary: ActionDescriber.describe(toolName: ev.toolName, input: ev.toolInput),
                agentId: ev.agentId,
                receivedAt: now
            )
            s.queue.append(request)
            s.status = .waitingPermission
            effects.append(.requestOpened(request))

        case "PostToolUse", "PostToolUseFailure":
            s.toolRunning = false
            if ev.isInterrupt == true {
                effects += closeAll(&s)
                s.status = .idle
                s.currentAction = "Прервано"
            } else {
                // В хуке нет tool_use_id: закрываем первый запрос с тем же именем инструмента.
                if let i = s.queue.firstIndex(where: { $0.toolName == ev.toolName }) {
                    effects.append(.requestClosed(requestId: s.queue.remove(at: i).requestId))
                }
                if s.status == .working || s.status == .waitingPermission || isNew {
                    s.status = s.queue.isEmpty ? .working : .waitingPermission
                }
            }

        case "Stop":
            effects += closeAll(&s)
            s.status = .done
            s.unseenDone = true
            s.toolRunning = false
            s.currentAction = ""
            refreshBranch(&s)
            effects.append(.sessionBecameDone(sessionId: s.sessionId))

        case "StopFailure":
            effects += closeAll(&s)
            s.status = .idle
            s.toolRunning = false
            s.currentAction = "Ошибка API"

        case "SessionEnd":
            effects += closeAll(&s)
            sessions[ev.sessionId] = nil
            effects.append(.sessionRemoved(sessionId: ev.sessionId))
            return effects

        default:
            break // Notification и прочее: только обновили lastEventAt
        }

        sessions[ev.sessionId] = s
        return effects
    }

    // MARK: действия владельца и фоновые проверки

    /// Владелец ответил на запрос из острова: карточка закрыта, ответ ушёл мосту.
    @discardableResult
    public mutating func resolve(requestId: String) -> Bool {
        for (id, var s) in sessions {
            if let i = s.queue.firstIndex(where: { $0.requestId == requestId }) {
                s.queue.remove(at: i)
                s.status = s.queue.isEmpty ? .working : .waitingPermission
                sessions[id] = s
                return true
            }
        }
        return false
    }

    /// Владелец открыл сессию: метка «готово» снимается.
    public mutating func markViewed(sessionId: String) {
        guard var s = sessions[sessionId] else { return }
        s.unseenDone = false
        if s.status == .done { s.status = .idle }
        sessions[sessionId] = s
    }

    /// «Работает», но событий нет давно и инструмент не выполняется → «простаивает».
    @discardableResult
    public mutating func sweepQuiet(now: Date, quietAfter: TimeInterval = 600) -> [String] {
        var changed: [String] = []
        for (id, var s) in sessions where s.status == .working && !s.toolRunning
            && now.timeIntervalSince(s.lastEventAt) > quietAfter {
            s.status = .idle
            s.currentAction = ""
            sessions[id] = s
            changed.append(id)
        }
        return changed
    }

    /// Убрать сессию без SessionEnd (процесс исчез).
    @discardableResult
    public mutating func remove(sessionId: String) -> [StoreEffect] {
        guard var s = sessions[sessionId] else { return [] }
        var effects = closeAll(&s)
        sessions[sessionId] = nil
        effects.append(.sessionRemoved(sessionId: sessionId))
        return effects
    }

    // MARK: представление

    /// Сессии по срочности, затем по проекту.
    public func snapshot() -> [Session] {
        sessions.values.sorted {
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency < $1.status.urgency }
            if $0.project != $1.project { return $0.project < $1.project }
            return $0.firstSeenAt < $1.firstSeenAt
        }
    }

    public func summary() -> Summary {
        var sum = Summary()
        for s in sessions.values {
            switch s.status {
            case .waitingPermission: sum.waiting += 1
            case .done: sum.done += 1
            case .working: sum.working += 1
            case .idle: sum.idle += 1
            }
        }
        sum.top = sessions.values.map(\.status).min { $0.urgency < $1.urgency }
        return sum
    }

    /// Подписи «проект · ветка»; одинаковые различаются суффиксом « #2», « #3» по порядку появления.
    public static func displayTitles(_ sessions: [Session]) -> [String: String] {
        func base(_ s: Session) -> String { s.branch.map { "\(s.project) · \($0)" } ?? s.project }
        var result: [String: String] = [:]
        let groups = Dictionary(grouping: sessions, by: base)
        for (title, group) in groups {
            let ordered = group.sorted { ($0.firstSeenAt, $0.sessionId) < ($1.firstSeenAt, $1.sessionId) }
            for (i, s) in ordered.enumerated() {
                result[s.sessionId] = i == 0 ? title : "\(title) #\(i + 1)"
            }
        }
        return result
    }

    public static func hostName(_ termProgram: String?) -> String? {
        switch termProgram {
        case "ghostty": return "Ghostty"
        case "vscode": return "VS Code"
        case let other?: return other
        case nil: return nil
        }
    }

    // MARK: внутреннее

    private func makeSession(_ msg: BridgeMessage, now: Date) -> Session {
        let root = msg.projectDir ?? msg.event.cwd ?? ""
        let name = (root as NSString).lastPathComponent
        return Session(
            sessionId: msg.event.sessionId,
            projectRoot: root,
            project: name.isEmpty ? "?" : name,
            branch: nil,
            status: .idle,
            currentAction: "",
            pid: msg.pid,
            processStartedAt: msg.processStartedAt,
            hostApp: nil,
            permissionMode: msg.event.permissionMode,
            firstSeenAt: now,
            lastEventAt: now,
            toolRunning: false,
            unseenDone: false,
            queue: []
        )
    }

    private func refreshBranch(_ s: inout Session) {
        if !s.projectRoot.isEmpty { s.branch = branchProvider(s.projectRoot) }
    }

    private func closeAll(_ s: inout Session) -> [StoreEffect] {
        let effects = s.queue.map { StoreEffect.requestClosed(requestId: $0.requestId) }
        s.queue = []
        return effects
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter SessionStoreTests`
Expected: PASS — `Executed 16 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/Session.swift Sources/TopbarCore/SessionStore.swift Tests/TopbarCoreTests/SessionStoreTests.swift
git commit -m "feat(core): session model and status state machine"
```

---

### Task 3: Ветка репозитория

**Files:**
- Create: `Sources/TopbarCore/BranchReader.swift`
- Test: `Tests/TopbarCoreTests/BranchReaderTests.swift`

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/BranchReaderTests.swift`

```swift
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
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'BranchReader' in scope`.

- [ ] **Step 3: Реализовать**

**Create:** `Sources/TopbarCore/BranchReader.swift`

```swift
import Foundation

public enum BranchReader {
    /// Имя ветки по `.git/HEAD` (выше по дереву от `dir`). Worktree (`.git` — файл) поддержан.
    /// Detached HEAD, каталог без git → nil.
    public static func branch(at dir: String) -> String? {
        var current = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        for _ in 0..<12 {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let headDir: URL
                if isDir.boolValue {
                    headDir = dotGit
                } else if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          text.hasPrefix("gitdir:") {
                    let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    headDir = URL(fileURLWithPath: path, relativeTo: current)
                } else {
                    return nil
                }
                guard let head = try? String(contentsOf: headDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
                    return nil
                }
                let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter BranchReaderTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/BranchReader.swift Tests/TopbarCoreTests/BranchReaderTests.swift
git commit -m "feat(core): read git branch from HEAD, worktrees supported"
```

---

### Task 4: Сведения о процессах

**Files:**
- Create: `Sources/TopbarCore/ProcessProbe.swift`
- Test: `Tests/TopbarCoreTests/ProcessProbeTests.swift`

Живость сессии проверяется парой «pid + время старта»: тот же pid с другим временем старта — это уже чужой процесс (pid переиспользован).

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/ProcessProbeTests.swift`

```swift
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
        XCTAssertEqual(ProcessProbe.ancestorPid(named: "sleep", from: p.processIdentifier), p.processIdentifier)
        XCTAssertNil(ProcessProbe.ancestorPid(named: "no-such-process-name", from: p.processIdentifier))
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'ProcessProbe' in scope`.

- [ ] **Step 3: Реализовать**

**Create:** `Sources/TopbarCore/ProcessProbe.swift`

```swift
import Foundation
import Darwin

public enum ProcessProbe {
    private static func info(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Время старта процесса (секунды с эпохи); nil, если процесса нет.
    public static func startTime(pid: Int32) -> Double? {
        guard let i = info(pid: pid) else { return nil }
        let t = i.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    public static func parentPid(of pid: Int32) -> Int32? {
        info(pid: pid).map { $0.kp_eproc.e_ppid }
    }

    public static func name(of pid: Int32) -> String? {
        guard var i = info(pid: pid) else { return nil }
        return withUnsafePointer(to: &i.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// Процесс жив и это тот же процесс (время старта совпадает), а не переиспользованный pid.
    public static func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        guard let started = startTime(pid: pid) else { return false }
        guard let startedAt else { return true }
        return abs(started - startedAt) < 2
    }

    /// Поднимается по дереву процессов от `pid` и возвращает первого предка с таким именем.
    public static func ancestorPid(named target: String, from pid: Int32, maxDepth: Int = 8) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            if name(of: current) == target { return current }
            guard let parent = parentPid(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter ProcessProbeTests`
Expected: PASS — `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/ProcessProbe.swift Tests/TopbarCoreTests/ProcessProbeTests.swift
git commit -m "feat(core): process start time, parent, name and liveness"
```

---

### Task 5: Сокет и логика моста

**Files:**
- Create: `Sources/TopbarCore/Sockets.swift`, `Sources/TopbarCore/BridgeRunner.swift`
- Test: `Tests/TopbarCoreTests/BridgeSocketTests.swift`

Закрепляемые правила спеки: нет сокета — мост молча выходит быстро; «принято» за ≤0,3 с; решение `allow`/`deny` печатается в формате хука; `none` и закрытие сокета освобождают мост сразу, а не по тайм-ауту; права сокета только для владельца; ядро узнаёт, что мост отключился.

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/BridgeSocketTests.swift`

```swift
import XCTest
@testable import TopbarCore

final class BridgeSocketTests: XCTestCase {
    func hookJSON(_ name: String, tool: String? = nil) -> Data {
        var d: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/work/topbar"]
        if let tool { d["tool_name"] = tool; d["tool_input"] = ["command": "mkdir x"] }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    func run(_ data: Data, path: String, ack: Double = 0.3, decision: Double = 5, env: [String: String] = [:]) -> Data? {
        BridgeRunner.run(stdin: data, environment: env, parentPid: getppid(), socketPath: path,
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
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'BridgeRunner' in scope`.

- [ ] **Step 3: Реализовать сокет и мост**

**Create:** `Sources/TopbarCore/Sockets.swift`

```swift
import Foundation
import Darwin

public enum SocketError: Error { case pathTooLong, system(String) }

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else { throw SocketError.pathTooLong }
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
    }
    return addr
}

private func withSockaddr<R>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func setNoSigPipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

// MARK: - клиент (мост)

public enum SocketClient {
    /// Подключение с тайм-аутом. nil — сокета нет, приложение не слушает или не успело принять.
    public static func connect(path: String, timeout: Double) -> Int32? {
        guard var addr = try? makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setNoSigPipe(fd)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withSockaddr(&addr) { Darwin.connect(fd, $0, $1) }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { close(fd); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buf -> Bool in
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Читает одну строку (без перевода строки). nil — тайм-аут или соединение закрыто до конца строки.
    public static func readLine(_ fd: Int32, timeout: Double) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { return nil }
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
    }
}

// MARK: - сервер (ядро)

public final class ReplyChannel {
    fileprivate let fd: Int32
    private var closed = false
    /// Вызывается, когда мост закрыл соединение.
    public var onClose: (() -> Void)?

    fileprivate init(fd: Int32) { self.fd = fd }

    public func send(_ reply: CoreReply) {
        guard !closed, let data = try? Wire.encode(reply) else { return }
        _ = SocketClient.writeAll(fd, data)
    }

    fileprivate func markClosed() {
        guard !closed else { return }
        closed = true
        onClose?()
    }
}

public final class SocketServer {
    public typealias Handler = (BridgeMessage, ReplyChannel) -> Void

    private let path: String
    private let queue: DispatchQueue
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private let maxMessageBytes = 8 * 1024 * 1024

    private final class Connection {
        let fd: Int32
        let channel: ReplyChannel
        var buffer = Data()
        var delivered = false
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd; self.channel = ReplyChannel(fd: fd) }
    }

    /// Все обработчики и колбэки каналов вызываются на `queue`.
    public init(path: String, queue: DispatchQueue, handler: @escaping Handler) {
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        var addr = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket: \(errno)") }
        guard withSockaddr(&addr, { Darwin.bind(fd, $0, $1) }) == 0 else {
            close(fd); throw SocketError.system("bind: \(errno)")
        }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { close(fd); throw SocketError.system("listen: \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            for c in connections.values { finish(c) }
            unlink(path)
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Разговаривать с сокетом должен только владелец той же учётной записи.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); continue }
            setNoSigPipe(fd)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let conn = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, unowned conn] in self?.readable(conn) }
            conn.source = source
            connections[fd] = conn
            source.resume()
        }
    }

    private func readable(_ conn: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(conn.fd, &chunk, chunk.count)
            if n > 0 {
                if !conn.delivered {
                    conn.buffer.append(chunk, count: n)
                    if conn.buffer.count > maxMessageBytes { finish(conn); return }
                    deliverIfComplete(conn)
                }
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            finish(conn) // EOF или ошибка
            return
        }
    }

    private func deliverIfComplete(_ conn: Connection) {
        guard let nl = conn.buffer.firstIndex(of: 0x0A) else { return }
        let line = conn.buffer.prefix(upTo: nl)
        conn.delivered = true
        conn.buffer = Data()
        guard let msg = try? Wire.decode(BridgeMessage.self, line: Data(line)) else { finish(conn); return }
        handler(msg, conn.channel)
    }

    private func finish(_ conn: Connection) {
        guard connections[conn.fd] != nil else { return }
        connections[conn.fd] = nil
        conn.source?.cancel()
        conn.source = nil
        conn.channel.markClosed()
        close(conn.fd)
    }
}
```

**Create:** `Sources/TopbarCore/BridgeRunner.swift`

```swift
import Foundation

/// Логика моста: прочитать событие хука, передать ядру, при запросе разрешения дождаться решения.
public enum BridgeRunner {
    /// Возвращает то, что нужно напечатать в stdout хука (JSON решения), либо nil — «без решения».
    public static func run(
        stdin: Data,
        environment: [String: String],
        parentPid: Int32,
        socketPath: String,
        ackTimeout: Double = 0.3,
        decisionTimeout: Double = 600,
        makeRequestId: () -> String = { UUID().uuidString }
    ) -> Data? {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: stdin) else { return nil }

        // Процесс сессии: CLAUDE_PID, иначе первый предок с именем claude, иначе родитель.
        let claudePid = environment["CLAUDE_PID"].flatMap { Int32($0) }
            ?? ProcessProbe.ancestorPid(named: "claude", from: parentPid)
            ?? parentPid

        let unattended = environment["CLAUDE_CODE_SESSION_ATTENDED"] == "0"
            || (environment["CLAUDE_CODE_ENTRYPOINT"]?.hasPrefix("sdk") ?? false)

        let message = BridgeMessage(
            requestId: makeRequestId(),
            event: event,
            pid: claudePid,
            processStartedAt: ProcessProbe.startTime(pid: claudePid),
            termProgram: environment["TERM_PROGRAM"],
            projectDir: environment["CLAUDE_PROJECT_DIR"],
            unattended: unattended
        )

        guard let fd = SocketClient.connect(path: socketPath, timeout: ackTimeout),
              let payload = try? Wire.encode(message),
              SocketClient.writeAll(fd, payload) else { return nil }
        defer { close(fd) }

        guard let ackLine = SocketClient.readLine(fd, timeout: ackTimeout),
              (try? Wire.decode(CoreReply.self, line: ackLine))?.kind == .ack else { return nil }

        guard event.hookEventName == "PermissionRequest" else { return nil }

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
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter BridgeSocketTests`
Expected: PASS — `Executed 9 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/Sockets.swift Sources/TopbarCore/BridgeRunner.swift Tests/TopbarCoreTests/BridgeSocketTests.swift
git commit -m "feat(core): unix socket server/client and bridge runner"
```

---

### Task 6: Установка хуков в settings.json

**Files:**
- Create: `Sources/TopbarCore/HookInstaller.swift`
- Test: `Tests/TopbarCoreTests/HookInstallerTests.swift`

Записи topbar узнаются по метке `# topbar-managed` в команде, поэтому установка повторяема, а удаление не трогает чужие хуки. Путь к мосту содержит пробел («Application Support»), поэтому он берётся в кавычки. Копий файла рядом не создаём (правило владельца): запись атомарная, а показанная перед ней разница — единственная «страховка».

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/HookInstallerTests.swift`

```swift
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

    func testDiffShowsOnlyAdditionsForFreshInstall() throws {
        let old = Data(#"{"model":"opus"}"#.utf8)
        let new = try HookInstaller.install(into: old, bridgePath: bridge)
        let diff = HookInstaller.diff(old: old, new: new)
        XCTAssertTrue(diff.contains("+ "))
        XCTAssertFalse(diff.contains("- "))
        XCTAssertTrue(diff.contains("topbar-managed"))
    }

    func testRejectsNonObjectSettings() {
        XCTAssertThrowsError(try HookInstaller.install(into: Data("[1,2]".utf8), bridgePath: bridge))
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'HookInstaller' in scope`.

- [ ] **Step 3: Реализовать**

**Create:** `Sources/TopbarCore/HookInstaller.swift`

```swift
import Foundation

/// Вписывает и убирает хуки topbar в settings.json Claude Code. Записи узнаются по метке в команде.
public enum HookInstaller {
    public static let marker = "# topbar-managed"

    /// Какие события слушаем и сколько секунд Claude Code ждёт хук.
    public static let events: [(name: String, timeout: Int)] = [
        ("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5),
        ("PermissionRequest", 600), ("PostToolUse", 5), ("PostToolUseFailure", 5),
        ("Stop", 5), ("StopFailure", 5), ("SessionEnd", 5),
    ]

    public enum InstallError: Error { case notAnObject }

    public static func command(bridgePath: String) -> String {
        let quoted = "'" + bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(marker)"
    }

    public static func install(into data: Data?, bridgePath: String) throws -> Data {
        var root = try parse(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (name, timeout) in events {
            var groups = (hooks[name] as? [[String: Any]] ?? []).compactMap(strippingManaged)
            groups.append(["hooks": [["type": "command", "command": command(bridgePath: bridgePath), "timeout": timeout]]])
            hooks[name] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func remove(from data: Data) throws -> Data {
        var root = try parse(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return try serialize(root) }
        for (name, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).compactMap(strippingManaged)
            hooks[name] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    public static func isInstalled(in data: Data?) -> Bool {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains(where: containsManaged)
        }
    }

    /// Построчная разница «было → стало» для показа владельцу перед записью.
    public static func diff(old: Data?, new: Data) -> String {
        let oldLines = ((try? parse(old)).flatMap { try? serialize($0) }).map(lines) ?? []
        let newLines = lines(new)
        var out: [String] = []
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .insert(_, let line, _): out.append("+ " + line)
            case .remove(_, let line, _): out.append("- " + line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: внутреннее

    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.notAnObject
        }
        return obj
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func isManaged(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) ?? false
    }

    private static func containsManaged(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains(where: isManaged)
    }

    /// Группа без наших хуков; пустая группа пропадает (nil).
    private static func strippingManaged(_ group: [String: Any]) -> [String: Any]? {
        var group = group
        let rest = (group["hooks"] as? [[String: Any]] ?? []).filter { !isManaged($0) }
        if rest.isEmpty { return nil }
        group["hooks"] = rest
        return group
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter HookInstallerTests`
Expected: PASS — `Executed 7 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/HookInstaller.swift Tests/TopbarCoreTests/HookInstallerTests.swift
git commit -m "feat(core): install/remove topbar hooks in settings.json"
```

---

### Task 7: SessionHub — склейка ядра

**Files:**
- Create: `Sources/TopbarCore/SessionHub.swift`
- Test: `Tests/TopbarCoreTests/SessionHubTests.swift`

`SessionHub` — то, что часть 2 подключит к окну острова: колбэки `onChange`, `onRequestOpened`, `onRequestClosed`, `onSessionDone`, метод `decide`, настройка `cardPolicy`. Закрепляемые правила: решение с карточки доходит до моста; ответ в терминале (`PostToolUse`) закрывает карточку и освобождает мост; если карточку показывать не надо, мост освобождается сразу, а статус остаётся «ждёт разрешения»; `AskUserQuestion`/`ExitPlanMode` и сессии без терминала не перехватываются; исчезнувший процесс убирает сессию.

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/SessionHubTests.swift`

```swift
import XCTest
@testable import TopbarCore

final class SessionHubTests: XCTestCase {
    func hook(_ name: String, sid: String = "s1", tool: String? = nil, extra: [String: Any] = [:]) -> Data {
        var d: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": "/work/topbar", "permission_mode": "default"]
        if let tool { d["tool_name"] = tool; d["tool_input"] = ["command": "mkdir x"] }
        extra.forEach { d[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    func bridge(_ data: Data, path: String, env: [String: String] = [:], decision: Double = 5) -> Data? {
        // Живой процесс сессии — сам тест: так проверка живости не уберёт сессию.
        var environment = ["CLAUDE_PID": "\(getpid())"]
        env.forEach { environment[$0.key] = $0.value }
        return BridgeRunner.run(stdin: data, environment: environment, parentPid: getppid(),
                                socketPath: path, decisionTimeout: decision)
    }

    func makeHub(path: String) -> SessionHub {
        SessionHub(socketPath: path, livenessInterval: 3600, branchProvider: { _ in "main" })
    }

    func testCardDecisionReachesBridgeAsAllow() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let opened = expectation(description: "opened")
        hub.onRequestOpened = { req, _ in
            hub.decide(requestId: req.requestId, allow: true)
            opened.fulfill()
        }
        try hub.start()
        defer { hub.stop() }

        _ = bridge(hook("UserPromptSubmit"), path: path)
        let out = bridge(hook("PermissionRequest", tool: "Bash"), path: path)
        wait(for: [opened], timeout: 2)
        let obj = try JSONSerialization.jsonObject(with: try XCTUnwrap(out)) as! [String: Any]
        XCTAssertEqual(((obj["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any])["behavior"] as? String, "allow")
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testPostToolUseClosesCardAndReleasesBridge() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let opened = expectation(description: "opened")
        let closed = expectation(description: "closed")
        hub.onRequestOpened = { _, _ in opened.fulfill() }
        hub.onRequestClosed = { _ in closed.fulfill() }
        try hub.start()
        defer { hub.stop() }

        var bridgeOutput: Data?? = .none
        let finished = expectation(description: "bridge finished")
        DispatchQueue.global().async {
            bridgeOutput = .some(self.bridge(self.hook("PermissionRequest", tool: "Bash"), path: path, decision: 20))
            finished.fulfill()
        }
        wait(for: [opened], timeout: 2)
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission)
        // Владелец ответил в терминале: приходит PostToolUse.
        _ = bridge(hook("PostToolUse", tool: "Bash"), path: path)
        wait(for: [closed, finished], timeout: 3)
        XCTAssertEqual(bridgeOutput, .some(nil), "мост выходит без решения")
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testCardPolicyFalseReleasesBridgeButKeepsStatusWaiting() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.cardPolicy = { _, _ in false }
        try hub.start()
        defer { hub.stop() }
        let started = Date()
        XCTAssertNil(bridge(hook("PermissionRequest", tool: "Bash"), path: path, decision: 20))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission)
    }

    func testQuestionToolsAndUnattendedSessionsAreNotIntercepted() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var opened = 0
        hub.onRequestOpened = { _, _ in opened += 1 }
        try hub.start()
        defer { hub.stop() }
        XCTAssertNil(bridge(hook("PermissionRequest", tool: "AskUserQuestion"), path: path))
        XCTAssertNil(bridge(hook("PermissionRequest", sid: "bg", tool: "Bash"), path: path,
                            env: ["CLAUDE_CODE_SESSION_ATTENDED": "0"]))
        hub.queue.sync {}
        XCTAssertEqual(opened, 0)
    }

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
        XCTAssertEqual(hub.snapshot().first?.status, .idle)
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
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'SessionHub' in scope`.

- [ ] **Step 3: Реализовать**

**Create:** `Sources/TopbarCore/SessionHub.swift`

```swift
import Foundation

/// Склеивает сокет, автомат статусов и проверку живости. Все колбэки вызываются на `queue`.
public final class SessionHub {
    public let queue = DispatchQueue(label: "topbar.hub")

    /// Показывать ли карточку по этому запросу. false — владелец смотрит на сессию, нет экрана и т. п.
    public var cardPolicy: (Session, PermissionRequest) -> Bool = { _, _ in true }
    public var onChange: (([Session]) -> Void)?
    public var onRequestOpened: ((PermissionRequest, Session) -> Void)?
    public var onRequestClosed: ((String) -> Void)?
    public var onSessionDone: ((Session) -> Void)?

    private var store: SessionStore
    private var server: SocketServer!
    private var channels: [String: ReplyChannel] = [:]
    private var timer: DispatchSourceTimer?
    private let livenessInterval: TimeInterval

    public init(
        socketPath: String,
        livenessInterval: TimeInterval = 10,
        branchProvider: @escaping (String) -> String? = BranchReader.branch(at:)
    ) {
        self.store = SessionStore(branchProvider: branchProvider)
        self.livenessInterval = livenessInterval
        self.server = SocketServer(path: socketPath, queue: queue) { [weak self] msg, channel in
            self?.handle(msg, channel)
        }
    }

    public func start() throws {
        try server.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + livenessInterval, repeating: livenessInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        server.stop()
    }

    /// Ответ владельца с карточки.
    public func decide(requestId: String, allow: Bool, denyMessage: String = "Отклонено в topbar") {
        queue.async { [self] in
            guard let channel = channels.removeValue(forKey: requestId) else { return } // уже закрыт
            channel.send(allow ? .allow() : .deny(denyMessage))
            store.resolve(requestId: requestId)
            notifyChange()
        }
    }

    public func markViewed(sessionId: String) {
        queue.async { [self] in
            store.markViewed(sessionId: sessionId)
            notifyChange()
        }
    }

    public func snapshot() -> [Session] { queue.sync { store.snapshot() } }

    /// Для тестов и диагностики: выполнить проверку живости немедленно.
    public func tickNow() { queue.sync { tick() } }

    // MARK: внутреннее (всё на queue)

    private func handle(_ msg: BridgeMessage, _ channel: ReplyChannel) {
        channel.send(.ack)
        let ev = msg.event
        let isRequest = ev.hookEventName == "PermissionRequest"

        // Сессии без терминала и инструменты-вопросы не перехватываем: решение остаётся у Claude Code.
        if isRequest && (msg.unattended || !PermissionPolicy.intercepts(toolName: ev.toolName)) {
            channel.send(.none)
            return
        }

        let effects = store.apply(msg, now: Date())

        if isRequest {
            if let session = store.sessions[ev.sessionId],
               let request = session.queue.first(where: { $0.requestId == msg.requestId }),
               cardPolicy(session, request) {
                channels[request.requestId] = channel
                channel.onClose = { [weak self] in self?.channels[request.requestId] = nil }
            } else {
                channel.send(.none)
            }
        }

        for effect in effects {
            switch effect {
            case .requestOpened(let request):
                if channels[request.requestId] != nil, let s = store.sessions[request.sessionId] {
                    onRequestOpened?(request, s)
                }
            case .requestClosed(let id):
                channels.removeValue(forKey: id)?.send(.none)
                onRequestClosed?(id)
            case .sessionBecameDone(let id):
                if let s = store.sessions[id] { onSessionDone?(s) }
            case .sessionRemoved:
                break
            }
        }
        notifyChange()
    }

    private func tick() {
        var changed = false
        for s in store.sessions.values where !ProcessProbe.isAlive(pid: s.pid, startedAt: s.processStartedAt) {
            for effect in store.remove(sessionId: s.sessionId) {
                if case .requestClosed(let id) = effect {
                    channels.removeValue(forKey: id)?.send(.none)
                    onRequestClosed?(id)
                }
            }
            changed = true
        }
        if !store.sweepQuiet(now: Date()).isEmpty { changed = true }
        if changed { notifyChange() }
    }

    private func notifyChange() { onChange?(store.snapshot()) }
}
```

- [ ] **Step 4: Прогнать весь набор**

Run: `swift test 2>&1 | grep -E "Executed|error" | tail -3`
Expected: `Executed 50 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/SessionHub.swift Tests/TopbarCoreTests/SessionHubTests.swift
git commit -m "feat(core): session hub wiring socket, store and liveness"
```

---

### Task 8: Мост и консоль разработчика

**Files:**
- Modify: `Sources/topbar-hook/main.swift`, `Sources/topbar-dev/main.swift` (заменить заглушки)

Исполняемые файлы только вызывают проверенную логику из `TopbarCore`, поэтому своих юнит-тестов у них нет: их проверяет задача 9.

- [ ] **Step 1: Заменить заглушки настоящим кодом**

**Overwrite:** `Sources/topbar-hook/main.swift`

```swift
import Foundation
import TopbarCore

// Мост хука: Claude Code запускает его на каждое событие. Любая неудача — тихий выход с кодом 0.
let input = FileHandle.standardInput.readDataToEndOfFile()
if let output = BridgeRunner.run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    parentPid: getppid(),
    socketPath: Paths.socketPath
) {
    FileHandle.standardOutput.write(output)
}
exit(0)
```

**Overwrite:** `Sources/topbar-dev/main.swift`

```swift
import Foundation
import TopbarCore

// Консоль разработчика: слушает хуки, печатает сессии, отвечает на запросы разрешений с клавиатуры.
// Нужна, пока нет окна острова; для проверки ядра и моста на настоящих сессиях Claude Code.

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    topbar-dev run
        слушать хуки и показывать сессии; на запрос разрешения отвечать y (разрешить) или n (отклонить)
    topbar-dev install-bridge --from <путь к topbar-hook>
        скопировать мост в стабильное место
    topbar-dev install --settings <settings.json> [--yes]
        показать, что допишется, и вписать хуки
    topbar-dev uninstall --settings <settings.json>
        убрать хуки topbar
    topbar-dev status --settings <settings.json>
        установлены ли хуки
    """)
    exit(2)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "run":
    let hub = SessionHub(socketPath: Paths.socketPath)
    var open: [PermissionRequest] = []   // трогаем только на hub.queue

    hub.onRequestOpened = { request, session in
        open.append(request)
        print("\n? [\(session.project)] \(request.summary)\n  ответ: y — разрешить, n — отклонить")
        fflush(stdout)
    }
    hub.onRequestClosed = { id in
        open.removeAll { $0.requestId == id }
        print("  (запрос закрыт: \(id.prefix(6)))")
    }
    hub.onSessionDone = { session in
        print("\u{7}✓ готово: \(session.project)")
    }
    hub.onChange = { sessions in
        let titles = SessionStore.displayTitles(sessions)
        let counts = Dictionary(grouping: sessions, by: \.status).mapValues(\.count)
        print("\n— ждёт \(counts[.waitingPermission] ?? 0) · работает \(counts[.working] ?? 0) · готово \(counts[.done] ?? 0) · простаивает \(counts[.idle] ?? 0) —")
        for s in sessions {
            let label: String
            switch s.status {
            case .waitingPermission: label = "ЖДЁТ  "
            case .working: label = "работает"
            case .done: label = "готово "
            case .idle: label = "простаивает"
            }
            print("  \(label)  \(titles[s.sessionId] ?? s.project)  \(s.currentAction)  [\(s.hostApp ?? "?")]")
        }
        fflush(stdout)
    }
    do { try hub.start() } catch { fail("не удалось открыть сокет \(Paths.socketPath): \(error)") }
    print("слушаю \(Paths.socketPath)")

    Thread.detachNewThread {
        while let line = readLine() {
            let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "n" else { continue }
            hub.queue.async {
                guard let request = open.first else { print("  (нет открытых запросов)"); return }
                open.removeFirst()
                hub.decide(requestId: request.requestId, allow: answer == "y")
                print("  → \(answer == "y" ? "разрешено" : "отклонено"): \(request.summary)")
            }
        }
    }
    dispatchMain()

case "install-bridge":
    guard let from = value(after: "--from", in: args) else { usage() }
    let target = Paths.bridgeInstallPath
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.copyItem(atPath: from, toPath: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
    } catch { fail("не удалось скопировать мост: \(error)") }
    print("мост установлен: \(target)")

case "install", "uninstall", "status":
    guard let settings = value(after: "--settings", in: args) else { usage() }
    let old = FileManager.default.contents(atPath: settings)
    do {
        switch command {
        case "status":
            print(HookInstaller.isInstalled(in: old) ? "хуки установлены" : "хуки не установлены")
        case "install":
            guard FileManager.default.isExecutableFile(atPath: Paths.bridgeInstallPath) else {
                fail("сначала: topbar-dev install-bridge --from <путь к topbar-hook>")
            }
            let new = try HookInstaller.install(into: old, bridgePath: Paths.bridgeInstallPath)
            print(HookInstaller.diff(old: old, new: new))
            if !args.contains("--yes") {
                print("\nЗаписать в \(settings)? [y/N] ", terminator: "")
                guard readLine()?.lowercased() == "y" else { print("отменено"); exit(0) }
            }
            try new.write(to: URL(fileURLWithPath: settings), options: .atomic)
            print("хуки вписаны")
        default:
            guard let old else { fail("нет файла \(settings)") }
            let new = try HookInstaller.remove(from: old)
            try new.write(to: URL(fileURLWithPath: settings), options: .atomic)
            print("хуки убраны")
        }
    } catch { fail("ошибка: \(error)") }

default:
    usage()
}
```

- [ ] **Step 2: Собрать и проверить справку**

Run: `swift build 2>&1 | tail -2 && .build/debug/topbar-dev bogus; echo "exit=$?"`
Expected: `Build complete!`, затем текст справки и `exit=2`.

- [ ] **Step 3: Проверить установщик на временном файле**

Run:
```bash
S=$(mktemp -d)/settings.json && echo '{"model":"opus"}' > "$S" && .build/debug/topbar-dev status --settings "$S"
```
Expected: `хуки не установлены`.

- [ ] **Step 4: Commit**

```bash
git add Sources/topbar-hook/main.swift Sources/topbar-dev/main.swift
git commit -m "feat: hook bridge executable and developer console"
```

---

### Task 9: Проверка на настоящих сессиях Claude Code (Ghostty и VS Code)

**Files:** изменений в коде нет; результаты записываются в спеку (шаг 9).

Эту задачу выполняют вместе с владельцем: нужны живые интерактивные сессии. Хуки вписываются **только** в настройки временной папки `/tmp/topbar-e2e` (они действуют лишь в сессиях, запущенных из неё), глобальный `~/.claude/settings.json` не трогается. Единственное место вне проекта, куда пишется приложение, — его собственный каталог данных `~/Library/Application Support/topbar/` (сокет и копия моста): так и задумано спекой («стабильный путь моста»).

- [ ] **Step 1: Собрать мост в релизном виде и установить в стабильное место**

Run:
```bash
swift build -c release --product topbar-hook && swift build --product topbar-dev
.build/debug/topbar-dev install-bridge --from .build/release/topbar-hook
```
Expected: `мост установлен: /Users/yer6o/Library/Application Support/topbar/bin/topbar-hook`.

- [ ] **Step 2: Вписать хуки во временную папку**

Run:
```bash
mkdir -p /tmp/topbar-e2e/.claude && echo '{}' > /tmp/topbar-e2e/.claude/settings.json
.build/debug/topbar-dev install --settings /tmp/topbar-e2e/.claude/settings.json
```
Expected: показан список строк с `+` (в том числе `topbar-managed`), вопрос `Записать …? [y/N]`; ответить `y`. Затем `.build/debug/topbar-dev status --settings /tmp/topbar-e2e/.claude/settings.json` → `хуки установлены`.

- [ ] **Step 3: Запустить консоль в окне Ghostty №1**

Run: `.build/debug/topbar-dev run`
Expected: `слушаю /Users/yer6o/Library/Application Support/topbar/hook.sock`.

- [ ] **Step 4: Открыть сессию в окне Ghostty №2 и пройти сценарии**

Run: `cd /tmp/topbar-e2e && claude --permission-mode default`

Для каждого пункта записать «как ожидалось / иначе (что именно)»:

| № | Действие в сессии (окно №2) | Ожидаемое в консоли (окно №1) |
| :- | :- | :- |
| a | Просто открыть сессию | Строка `простаивает  topbar-e2e  [Ghostty]` (проект — по `CLAUDE_PROJECT_DIR`) |
| b | Написать `выполни команду mkdir probe-a`, **не отвечая в окне №2** — в окне №1 нажать `y` | Строка `работает`, затем `? [topbar-e2e] Bash: mkdir probe-a`; после `y` диалог в окне №2 закрывается сам, команда выполняется, потом `✓ готово` со звонком |
| c | `mkdir probe-b`, ответить **в окне №2** | `(запрос закрыт: …)`, статус возвращается в `работает` и затем в `готово` |
| d | `mkdir probe-c`, в окне №1 нажать `n` | Claude сообщает об отказе с текстом `Отклонено в topbar` |
| e | Попросить `sleep 60`, прервать клавишей Esc | Через несколько секунд статус `простаивает` с пометкой `Прервано`, не `работает` |
| f | В **третьем** окне: `cd /tmp/topbar-e2e && claude -p "выполни mkdir probe-d" --permission-mode default` | Карточки (`?`) **нет**; мост не мешает |
| g | Закрыть окно №2 крестиком при открытой сессии | Строка исчезает не позже чем через ~10 с (записать: исчезла сразу по `SessionEnd` или по проверке живости) |
| h | В новой сессии выполнить `/clear` | Записать: осталась одна строка или стало две (меняется ли `session_id`) |

- [ ] **Step 5: Проверить признаки «без терминала» на интерактивной сессии**

Пункт b уже это проверяет: если в интерактивной сессии карточка (`?`) появилась, значит `CLAUDE_CODE_SESSION_ATTENDED` / `CLAUDE_CODE_ENTRYPOINT` не принимают интерактивную сессию за «без терминала». Если карточки нет — переписать условие `unattended` в `Sources/TopbarCore/BridgeRunner.swift` по реальным значениям (временно залогировать окружение хука, как делал пробный скрипт опыта) и повторить пункт b.

- [ ] **Step 6: Повторить пункты a–c в терминале VS Code**

Открыть `/tmp/topbar-e2e` в VS Code, запустить `claude --permission-mode default` во встроенном терминале и пройти a, b, c.
Expected: то же, но в скобках `[VS Code]`. Записать, какое значение пришло в `TERM_PROGRAM` и отличается ли что-то в поведении.

- [ ] **Step 7: Проверить скорость моста**

Run (при остановленной консоли, то есть без слушателя): `cd /tmp/topbar-e2e && time (echo '{"hook_event_name":"Stop","session_id":"x"}' | "$HOME/Library/Application Support/topbar/bin/topbar-hook")`
Expected: завершается за доли секунды, без вывода и без ошибок (приложение не запущено — мост молча выходит).

- [ ] **Step 8: Убрать за собой**

Run:
```bash
.build/debug/topbar-dev uninstall --settings /tmp/topbar-e2e/.claude/settings.json
rm -rf /tmp/topbar-e2e
```
Expected: `хуки убраны`. (Каталог `~/Library/Application Support/topbar/` оставить: он понадобится приложению.)

- [ ] **Step 9: Записать результаты в спеку и закоммитить**

Modify: `docs/specs/2026-11-03-topbar-mvp.md` — в разделе «Результаты опыта с хуками» добавить пункты по a–h и VS Code (что подтвердилось, что оказалось иначе), в «Открытых вопросах» закрыть вопросы 2–4 и дописать новые, если нашлись. Если что-то из таблицы шага 4 оказалось иначе, чем ожидалось, — сначала исправить код (с новым тестом, который воспроизводит расхождение), потом повторить пункт.

```bash
git add docs/specs/2026-11-03-topbar-mvp.md
git commit -m "docs: record end-to-end results of hook bridge on real sessions"
```

---

### Task 10: Памятка по разработке и итоговая проверка

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Дописать в `README.md` раздел «Разработка»**

Append to `README.md`:

```markdown

## Разработка

Нужен Xcode 27+ (лицензия принята). Из корня репозитория:

- `swift test` — все тесты ядра и моста;
- `swift build` — собрать мост `topbar-hook` и консоль `topbar-dev`;
- `.build/debug/topbar-dev run` — слушать хуки и показывать сессии в терминале.

Установка хуков в настройки Claude Code — `topbar-dev install --settings <файл>` (показывает разницу и спрашивает подтверждение); убрать — `topbar-dev uninstall`.
```

- [ ] **Step 2: Полный прогон**

Run: `swift test 2>&1 | grep -E "Executed|error" | tail -3`
Expected: `Executed 50 tests, with 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add development notes to README"
```

- [ ] **Step 4: Отчёт владельцу и предложение интеграции**

Не мержить и не пушить самостоятельно: описать, что готово, чем проверено (тесты + таблица шага 4 задачи 9), и предложить, как влить ветку `feat/core-bridge` (решает владелец).

---

## Самопроверка плана по спеке

| Требование спеки | Где реализовано |
| :- | :- |
| Мост: быстрый выход, нет сокета — тихо (раздел «Мост: правила») | Task 5 (`testNoServerMeansSilentNilQuickly`), Task 9 шаг 7 |
| Подтверждение «принято» ≤200 мс, отдельно от ожидания решения | Task 5 (`ackTimeout`), `BridgeRunner` |
| Решение `allow`/`deny` закрывает диалог; хук не прерывается при ответе в терминале; карточку снимает ядро по `PostToolUse` | Task 5, Task 7 (`testPostToolUseClosesCardAndReleasesBridge`), Task 9 b–c |
| «Без решения», если карточку не показываем | Task 7 (`cardPolicy`, `testCardPolicyFalse…`) |
| Исключения: `AskUserQuestion`, `ExitPlanMode`, сессии без терминала | Task 2 (`PermissionPolicy`), Task 7, Task 9 f |
| Идентификатор запроса генерирует мост; pid из `CLAUDE_PID`/предка; корень проекта из `CLAUDE_PROJECT_DIR` | Task 5 (`BridgeRunner`), Task 4 |
| Сокет: каталог 0700, права 0600, проверка владельца пира | Task 5 (`testSocketPermissionsAreOwnerOnly`, `getpeereid`) |
| Установка/удаление хуков с меткой, показ разницы, без копий файла | Task 6, Task 8 (`topbar-dev install`), Task 9 шаги 2 и 8 |
| Автомат: все переходы, очередь, прерывание, `StopFailure`, тишина 10 мин без выполняющегося инструмента, upsert по `session_id`, `compact` | Task 2 |
| Подпись «проект · ветка», суффикс `#2`, worktree/detached HEAD | Task 2 (`displayTitles`), Task 3 |
| Сводка и приоритет статусов | Task 2 (`Summary`, `urgency`) |
| Проверка живости раз в 10 с по паре pid+время старта | Task 4, Task 7 (`testDeadProcessIsRemovedByLivenessTick`) |
| Открытые вопросы 2–4 (VS Code, закрытие окна, `/clear`) | Task 9 шаги 4 g–h и 6 |
| Оверлей, карточка, меню в строке меню, звук, переход к сессии, «владелец смотрит», запуск при входе, сон/монитор, обрезка длинного ввода на карточке, режим разрешений значком | **Часть 2** (отдельный план после задачи 9) |

Пробелы внутри части 1: нет. Типы и имена сверены между задачами (`BridgeMessage`, `CoreReply`, `SessionStore.apply/resolve/markViewed/sweepQuiet/remove`, `SessionHub.decide/markViewed/snapshot/tickNow`, `HookInstaller.install/remove/isInstalled/diff`); весь код в плане скомпилирован и прогнан (50 тестов, 0 сбоев) на Xcode 27.2 / Swift 6.4.2 перед записью.

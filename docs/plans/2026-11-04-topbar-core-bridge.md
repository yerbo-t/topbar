# topbar: ядро и мост хуков — план реализации (часть 1 из 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Рабочая «невидимая» половина topbar: мост хука + ядро сессий Claude Code (сокет, автомат статусов, ответы на запросы разрешений, проверка живости, установка хуков), проверенная юнит-тестами и на настоящих сессиях в Ghostty и VS Code через консоль разработчика.

**Architecture:** Swift Package из трёх целей. `TopbarCore` (библиотека) — вся логика: чистый автомат статусов `SessionStore`, Unix-сокет с кадрированием «одна строка JSON», `BridgeRunner` (логика моста), `SessionHub` (склейка сокета, автомата и проверки живости), `HookInstaller`. `topbar-hook` — крошечный исполняемый файл-мост, который Claude Code запускает по событиям. `topbar-dev` — консоль разработчика вместо окна острова. Данные идут Claude Code → мост → ядро → (позже) оверлей; назад идёт только решение владельца.

**Tech Stack:** Swift 6.4 (режим языка 5, `swift-tools-version: 5.10`), SwiftPM, XCTest, Foundation + Darwin (POSIX-сокеты, `sysctl`, `poll`), macOS 14+.

**Спека:** `docs/specs/2026-11-03-topbar-mvp.md` (утверждена 2026-11-04; уточнена после ревью плана).

---

## Границы этого плана

Часть 1 (этот файл) даёт всё, что не требует окна. Часть 2 (оверлей на вырезе, карточка, иконка в строке меню, звук, переход к сессии, определение «владелец смотрит», запуск при входе, сон/смена экрана, сборка `.app`) пишется отдельным планом **после** того, как часть 1 пройдёт проверку на настоящих сессиях: оверлею нужны подтверждённые факты (задача 9), а не догадки.

**Что часть 2 получит готовым от части 1:** `SessionHub` с колбэками (`onChange`, `onRequestOpened`, `onRequestClosed`, `onSessionDone`), `decide(requestId:allow:completion:)`, `autoOpenPolicy` (раскрывать ли остров сам), `releaseAllCards()` (для сна и закрытой крышки), `markViewed`, снимок сессий с полным вводом запросов, терминалом и признаками окна.

**Решения плана, отличающиеся от первоначальной спеки (спека обновлена):**
- Событие `Notification` не подписываем: в переходах оно не участвует, а каждая подписка — лишний запуск процесса.
- Тайм-аут хуков, кроме `PermissionRequest`, — 5 с (мост сам выходит за 0,3 с); для `PermissionRequest` — 600 с (потолок на случай, если ядро не ответит). Побочный эффект: бюджет `SessionEnd` во всех настройках Claude Code поднимается до 60 с; на практике не заметно, потому что мост выходит за доли секунды.
- Канал к мосту держится, пока запрос открыт, даже когда остров не раскрывается сам: опыт показал, что терминал хука не ждёт.
- Сессии без терминала игнорируются целиком (ни строки, ни звука); вопросы `AskUserQuestion` / `ExitPlanMode` показываются как «ждёт» без кнопок.
- Признаки «сессия без терминала» (`CLAUDE_CODE_SESSION_ATTENDED=0` или `CLAUDE_CODE_ENTRYPOINT=sdk…`) и номер процесса (`CLAUDE_PID`) — недокументированные переменные окружения хука, замеченные в Claude Code 2.1.317; их значения на интерактивной сессии проверяются в задаче 9. Запасной путь для номера — подъём по дереву до процесса `claude` / `claude.exe`; не нашли — номер 0 и проверка живости для такой сессии не применяется.
- Привязка запроса к вызову: в `PermissionRequest` нет `tool_use_id`, поэтому он сопоставляется с `PreToolUse` по имени инструмента и отпечатку ввода; `PostToolUse` закрывает запрос по `tool_use_id` (наличие поля проверяется в задаче 9).

**Что изменено по ревью плана свежим контекстом (12 замечаний):** прерывание и отказ в терминале (резервные правила и честный список ограничений в спеке), полный ввод запроса на карточке, мёртвые каналы и взаимоблокировки (колбэки на отдельной очереди, `decide` сообщает о доставке, `releaseAllCards`), дедупликация по паре «процесс + время старта», имена процесса `claude` / `claude.exe`, единый срок 0,3 с и неблокирующая запись в мосту, список выполняющихся вызовов вместо флага, расширенная проверка на живых сессиях, защита сокета и бережный установщик хуков.

**Что в этом плане сознательно не делается:** окно острова, звук, меню, определение «смотрит на сессию» (`autoOpenPolicy` по умолчанию раскрывает всегда), запуск при входе, переход к окну сессии. Всё это — часть 2.

## Структура файлов

```
Package.swift
.gitignore                                  (дописать .build/)
Sources/TopbarCore/
  JSONValue.swift       произвольный JSON для tool_input
  HookEvent.swift       событие хука (snake_case из stdin), облегчённая копия
  Wire.swift            BridgeMessage, CoreReply, кадрирование строк
  Paths.swift           каталог данных, путь сокета, путь моста
  Session.swift         Session, RunningTool, PermissionRequest, Summary, PermissionPolicy, ActionDescriber
  SessionStore.swift    автомат статусов (чистая логика)
  BranchReader.swift    ветка из .git/HEAD (включая worktree)
  ProcessProbe.swift    время старта, родитель, имя, терминал, дети, живость процесса
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
Expected: `Xcode 27.x`, `Apple Swift version 6.4.x`, `Swift Package Manager - Swift 6.4.x`. Если вместо этого `You have not agreed to the Xcode license` — попросить владельца выполнить в обычном терминале (не через `!`) `sudo xcodebuild -license accept`.

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
    public var toolUseId: String?
    public var agentType: String?

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
        case toolUseId = "tool_use_id"
        case agentType = "agent_type"
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
        notificationType: String? = nil,
        toolUseId: String? = nil,
        agentType: String? = nil
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
        self.toolUseId = toolUseId
        self.agentType = agentType
    }

    /// Облегчённая копия для событий, которым не нужен полный ввод инструмента:
    /// остаются только `command` / `file_path` / `notebook_path`, обрезанные до 300 символов.
    /// Полный ввод нужен только запросу разрешения (его владелец должен увидеть целиком).
    public func slimmed() -> HookEvent {
        var copy = self
        guard hookEventName != "PermissionRequest", case .object(let object)? = toolInput else { return copy }
        var keep: [String: JSONValue] = [:]
        for key in ["command", "file_path", "notebook_path"] {
            if case .string(let text)? = object[key] { keep[key] = .string(String(text.prefix(300))) }
        }
        copy.toolInput = .object(keep)
        return copy
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
    /// Процесс `claude` сессии; 0 — не удалось определить (тогда проверка живости не применяется).
    public var pid: Int32
    public var processStartedAt: Double?
    public var termProgram: String?
    public var projectDir: String?
    /// Сессия без терминала (`claude -p`, SDK): карточки ей не нужны.
    public var unattended: Bool
    /// Терминальное устройство процесса `claude` (например, `ttys003`) — понадобится для поиска окна.
    public var tty: String?
    /// Признаки окна из окружения хука (`GHOSTTY_*`, `VSCODE_*`, `ITERM_*`, `TERM_SESSION_ID`).
    public var hints: [String: String]

    public init(
        requestId: String,
        event: HookEvent,
        pid: Int32,
        processStartedAt: Double? = nil,
        termProgram: String? = nil,
        projectDir: String? = nil,
        unattended: Bool = false,
        tty: String? = nil,
        hints: [String: String] = [:]
    ) {
        self.requestId = requestId
        self.event = event
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.termProgram = termProgram
        self.projectDir = projectDir
        self.unattended = unattended
        self.tty = tty
        self.hints = hints
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
Expected: PASS — `Executed 7 tests, with 0 failures`

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

Автомат — чистая логика: время и ветку ему подают снаружи, поэтому он целиком проверяется без процессов и сокетов. Правила взяты из раздела «Ядро сессий» спеки; ключевые решения закреплены тестами: `compact` не сбрасывает статус; прерывание и `StopFailure` не оставляют сессию в «работает»; запоздавший `PostToolUse` не оживляет закончившуюся сессию; завершившийся вызов не закрывает чужую карточку (привязка по `tool_use_id`); быстрый вызов не снимает признак долгой команды; висящий запрос закрывается следующим инструментом сессии; прервавшаяся клавишей Esc команда определяется по отсутствию дочерних процессов; один процесс — одна сессия; запоздавший `SessionEnd` старого процесса живую запись не убирает; ввод запроса хранится целиком.

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
        store.apply(Fx.msg("PermissionRequest", sid: "late", req: "r9", tool: "Bash", pid: 101), now: now)
        XCTAssertEqual(status("late"), .waitingPermission)
        store.apply(Fx.msg("PostToolUse", sid: "other", tool: "Bash", pid: 102), now: now)
        XCTAssertEqual(status("other"), .working)
        store.apply(Fx.msg("Stop", sid: "third", pid: 103), now: now)
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
        // Разные сессии — разные процессы (иначе автомат посчитает прежнюю призраком).
        store.apply(Fx.msg("UserPromptSubmit", sid: "a", pid: 101), now: now)
        store.apply(Fx.msg("Stop", sid: "b", pid: 102), now: now)
        store.apply(Fx.msg("SessionStart", sid: "c", source: "startup", pid: 103), now: now)
        XCTAssertEqual(store.summary(), Summary(waiting: 0, working: 1, done: 1, idle: 1, top: .done))
        store.apply(Fx.msg("PermissionRequest", sid: "a", req: "r", tool: "Bash", pid: 101), now: now)
        XCTAssertEqual(store.summary().top, .waitingPermission)
        XCTAssertEqual(store.snapshot().first?.sessionId, "a")
    }

    func testDuplicateTitlesGetSuffix() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "a", pid: 101), now: now)
        store.apply(Fx.msg("UserPromptSubmit", sid: "b", pid: 102), now: now.addingTimeInterval(5))
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

    // MARK: привязка запросов к вызовам, параллельные инструменты

    func testFinishedPreApprovedToolDoesNotCloseAnotherPendingRequest() {
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("ls"), toolUseId: "u1"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("rm x"), toolUseId: "u2"), now: now)
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("rm x")), now: now)
        XCTAssertEqual(store.sessions["s1"]?.queue.first?.toolUseId, "u2")

        store.apply(Fx.msg("PostToolUse", tool: "Bash", toolUseId: "u1"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.queue.count, 1, "чужой PostToolUse не закрывает запрос")
        XCTAssertEqual(status(), .waitingPermission)

        let effects = store.apply(Fx.msg("PostToolUse", tool: "Bash", toolUseId: "u2"), now: now)
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(status(), .working)
    }

    func testParallelToolsAreTrackedIndividually() {
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("sleep 600"), toolUseId: "u1"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Read", toolUseId: "u2"), now: now)
        store.apply(Fx.msg("PostToolUse", tool: "Read", toolUseId: "u2"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, true, "быстрый Read не снимает признак долгой команды")
        store.apply(Fx.msg("PostToolUse", tool: "Bash", toolUseId: "u1"), now: now)
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, false)
    }

    func testLaterPreToolUseClosesRequestsAnsweredInTerminal() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash("a")), now: now)
        // Параллельный вызов стартует сразу: запрос ещё актуален.
        store.apply(Fx.msg("PreToolUse", tool: "Read"), now: now.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]?.queue.count, 1)
        // Через 5 с сессия начала новый инструмент: значит, на запрос уже ответили (например, отказом в терминале).
        let effects = store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("b")), now: now.addingTimeInterval(5))
        XCTAssertEqual(effects, [.requestClosed(requestId: "r1")])
        XCTAssertEqual(status(), .working)
    }

    func testStaleBashWithoutChildProcessesGoesIdleAfterEsc() {
        store.apply(Fx.msg("UserPromptSubmit"), now: now)
        store.apply(Fx.msg("PreToolUse", tool: "Bash", input: Fx.bash("sleep 600"), toolUseId: "u1"), now: now)
        let later = now.addingTimeInterval(21)
        XCTAssertEqual(store.sweepQuiet(now: later, hasChildProcess: { _ in true }), [], "команда ещё идёт")
        XCTAssertEqual(store.sweepQuiet(now: later, hasChildProcess: { _ in false }), ["s1"])
        XCTAssertEqual(status(), .idle)
        XCTAssertEqual(store.sessions["s1"]?.toolRunning, false)
    }

    func testNonBashToolIsNotTreatedAsStaleByChildCheck() {
        store.apply(Fx.msg("PreToolUse", tool: "WebFetch", toolUseId: "u1"), now: now)
        XCTAssertEqual(store.sweepQuiet(now: now.addingTimeInterval(120), hasChildProcess: { _ in false }), [])
        XCTAssertEqual(status(), .working)
    }

    // MARK: идентичность процесса

    func testLateSessionEndFromOldProcessDoesNotKillResumedSession() {
        store.apply(Fx.msg("SessionStart", source: "startup", pid: 100, started: 1000), now: now)
        store.apply(Fx.msg("SessionStart", source: "resume", pid: 200, started: 2000), now: now)
        XCTAssertEqual(store.sessions["s1"]?.pid, 200)
        let effects = store.apply(Fx.msg("SessionEnd", pid: 100, started: 1000), now: now)
        XCTAssertEqual(effects, [])
        XCTAssertNotNil(store.sessions["s1"])
        store.apply(Fx.msg("SessionEnd", pid: 200, started: 2000), now: now)
        XCTAssertNil(store.sessions["s1"])
    }

    func testNewSessionOnSameProcessRemovesGhost() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "old", pid: 100, started: 1000), now: now)
        let effects = store.apply(Fx.msg("SessionStart", sid: "new", source: "clear", pid: 100, started: 1000), now: now)
        XCTAssertEqual(effects, [.sessionRemoved(sessionId: "old")])
        XCTAssertNil(store.sessions["old"])
        XCTAssertNotNil(store.sessions["new"])
    }

    func testUnknownPidNeverTriggersGhostRemoval() {
        store.apply(Fx.msg("UserPromptSubmit", sid: "a", pid: 0, started: nil), now: now)
        store.apply(Fx.msg("UserPromptSubmit", sid: "b", pid: 0, started: nil), now: now)
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testSessionEndForUnknownSessionIsNoop() {
        XCTAssertEqual(store.apply(Fx.msg("SessionEnd", sid: "never-seen"), now: now), [])
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: содержимое запроса

    func testRequestKeepsFullCommandAndAgentType() {
        let command = "echo hi\nrm -rf ~/important"
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash(command), agentType: "general-purpose"), now: now)
        let r = store.sessions["s1"]!.queue[0]
        XCTAssertEqual(r.summary, "Bash: echo hi")
        XCTAssertEqual(r.detail, command, "владелец видит всю команду, а не первую строку")
        XCTAssertEqual(r.agentType, "general-purpose")
        XCTAssertTrue(r.cardable)
    }

    func testVeryLongInputIsTruncatedWithNote() {
        let command = String(repeating: "a", count: 9000)
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "Bash", input: Fx.bash(command)), now: now)
        let detail = store.sessions["s1"]!.queue[0].detail
        XCTAssertTrue(detail.hasSuffix("показано не всё"))
        XCTAssertLessThan(detail.count, 4100)
    }

    func testQuestionToolMakesSessionWaitButWithoutCard() {
        store.apply(Fx.msg("PermissionRequest", req: "r1", tool: "AskUserQuestion"), now: now)
        XCTAssertEqual(status(), .waitingPermission)
        XCTAssertFalse(store.sessions["s1"]!.queue[0].cardable)
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

/// Инструмент, который сессия начала (`PreToolUse`) и ещё не закончила (`PostToolUse`).
public struct RunningTool: Equatable, Sendable {
    public let toolUseId: String?
    public let toolName: String
    /// Отпечаток ввода (команда или путь файла): по нему запрос разрешения привязывается к вызову,
    /// потому что в `PermissionRequest` нет `tool_use_id`.
    public let fingerprint: String
    public let startedAt: Date
}

public struct PermissionRequest: Equatable, Sendable {
    public let requestId: String
    public let sessionId: String
    public let toolName: String
    /// Одна строка для списка («Bash: pnpm test»).
    public let summary: String
    /// Полный ввод инструмента для карточки: владелец должен видеть всё, что разрешает.
    public let detail: String
    public let agentId: String?
    public let agentType: String?
    /// `tool_use_id` вызова, если удалось привязать запрос к `PreToolUse`.
    public let toolUseId: String?
    public let receivedAt: Date
    /// false — вопросы вроде `AskUserQuestion`: сессия «ждёт», но кнопок «разрешить/отклонить» нет.
    public let cardable: Bool
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
    public var tty: String?
    public var hints: [String: String]
    public var permissionMode: String?
    public var firstSeenAt: Date
    public var lastEventAt: Date
    public var running: [RunningTool]
    public var unseenDone: Bool
    public var queue: [PermissionRequest]

    public var toolRunning: Bool { !running.isEmpty }
}

public struct Summary: Equatable, Sendable {
    public var waiting = 0
    public var working = 0
    public var done = 0
    public var idle = 0
    /// Самый срочный статус из имеющихся (по нему красится остров).
    public var top: SessionStatus?
}

/// Какие инструменты остров не превращает в карточку: кнопки «разрешить/отклонить» для них бессмысленны.
public enum PermissionPolicy {
    public static let passthroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public static func intercepts(toolName: String?) -> Bool {
        guard let toolName else { return true }
        return !passthroughTools.contains(toolName)
    }
}

public enum ActionDescriber {
    /// Одна строка о вызове инструмента.
    public static func describe(toolName: String?, input: JSONValue?) -> String {
        guard let toolName else { return "" }
        switch toolName {
        case "Bash":
            return "Bash: " + oneLine(input?["command"]?.stringValue ?? "", limit: 80)
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
            let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue ?? ""
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? toolName : "\(toolName) \(name)"
        default:
            return toolName
        }
    }

    /// Полный текст для карточки (ограничен 4000 символами; обрезка помечается).
    public static func detail(toolName: String?, input: JSONValue?, limit: Int = 4000) -> String {
        var text: String
        if toolName == "Bash", let command = input?["command"]?.stringValue {
            text = command
        } else if let input, let data = try? Self.encoder.encode(input) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        if text.count > limit { text = String(text.prefix(limit)) + "\n… показано не всё" }
        return text
    }

    /// Отпечаток ввода для связи `PermissionRequest` ↔ `PreToolUse`.
    public static func fingerprint(toolName: String?, input: JSONValue?) -> String {
        let value = input?["command"]?.stringValue ?? input?["file_path"]?.stringValue
            ?? input?["notebook_path"]?.stringValue ?? ""
        return String(value.prefix(300))
    }

    public static func oneLine(_ text: String, limit: Int) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
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

    /// Запрос, висящий дольше этого срока, закрывается следующим `PreToolUse` той же сессии:
    /// пока диалог открыт, сессия не может начать новый инструмент (параллельные вызовы
    /// стартуют вместе с первым, то есть в первые секунды).
    public static let staleRequestAge: TimeInterval = 3

    public init(branchProvider: @escaping (String) -> String? = { _ in nil }) {
        self.branchProvider = branchProvider
    }

    // MARK: события хуков

    @discardableResult
    public mutating func apply(_ msg: BridgeMessage, now: Date) -> [StoreEffect] {
        let ev = msg.event
        var effects: [StoreEffect] = []

        // Один процесс — одна сессия: если на тот же процесс пришла другая, прежняя уже закончилась
        // (/clear, потерянный SessionEnd), и призрак с живым pid иначе не исчез бы.
        if msg.pid > 0, let started = msg.processStartedAt {
            for (id, other) in sessions where id != ev.sessionId && other.pid == msg.pid
                && Self.sameStart(other.processStartedAt, started) {
                effects += remove(sessionId: id)
            }
        }

        if ev.hookEventName == "SessionEnd" {
            // Запоздавший SessionEnd прежнего процесса (resume) не должен убивать живую запись.
            guard var s = sessions[ev.sessionId], Self.sameProcess(s, msg) else { return effects }
            effects += closeAll(&s)
            sessions[ev.sessionId] = nil
            effects.append(.sessionRemoved(sessionId: ev.sessionId))
            return effects
        }

        var existing = sessions[ev.sessionId]
        if var old = existing, ev.hookEventName == "SessionStart", !Self.sameProcess(old, msg) {
            // Тот же session_id, но другой процесс (resume): прежняя запись принадлежала старому процессу.
            effects += closeAll(&old)
            sessions[ev.sessionId] = nil
            existing = nil
        }
        let isNew = existing == nil
        var s = existing ?? makeSession(msg, now: now)

        if msg.pid > 0 { s.pid = msg.pid }
        if let started = msg.processStartedAt { s.processStartedAt = started }
        if let host = Self.hostName(msg.termProgram) { s.hostApp = host }
        if let tty = msg.tty { s.tty = tty }
        if !msg.hints.isEmpty { s.hints = msg.hints }
        if let mode = ev.permissionMode { s.permissionMode = mode }
        s.lastEventAt = now

        switch ev.hookEventName {
        case "SessionStart":
            if !isNew && ev.source != "compact" {
                effects += closeAll(&s)
                s.status = .idle
                s.running = []
                s.currentAction = ""
            }
            refreshBranch(&s)

        case "UserPromptSubmit":
            effects += closeAll(&s)
            s.status = .working
            s.unseenDone = false
            s.running = []
            s.currentAction = "Думает"
            refreshBranch(&s)

        case "PreToolUse":
            // Сессия начала новый инструмент → висящие давно запросы уже решены в терминале.
            let stale = s.queue.filter { now.timeIntervalSince($0.receivedAt) > Self.staleRequestAge }
            for request in stale {
                s.queue.removeAll { $0.requestId == request.requestId }
                effects.append(.requestClosed(requestId: request.requestId))
            }
            s.running.append(RunningTool(
                toolUseId: ev.toolUseId,
                toolName: ev.toolName ?? "?",
                fingerprint: ActionDescriber.fingerprint(toolName: ev.toolName, input: ev.toolInput),
                startedAt: now))
            s.currentAction = ActionDescriber.describe(toolName: ev.toolName, input: ev.toolInput)
            s.status = s.queue.isEmpty ? .working : .waitingPermission

        case "PermissionRequest":
            let name = ev.toolName ?? "?"
            let fingerprint = ActionDescriber.fingerprint(toolName: ev.toolName, input: ev.toolInput)
            let linked = Set(s.queue.compactMap(\.toolUseId))
            let match = s.running.last {
                $0.toolName == name && $0.fingerprint == fingerprint && !($0.toolUseId.map(linked.contains) ?? false)
            }
            let request = PermissionRequest(
                requestId: msg.requestId,
                sessionId: ev.sessionId,
                toolName: name,
                summary: ActionDescriber.describe(toolName: ev.toolName, input: ev.toolInput),
                detail: ActionDescriber.detail(toolName: ev.toolName, input: ev.toolInput),
                agentId: ev.agentId,
                agentType: ev.agentType,
                toolUseId: match?.toolUseId,
                receivedAt: now,
                cardable: PermissionPolicy.intercepts(toolName: ev.toolName)
            )
            s.queue.append(request)
            s.status = .waitingPermission
            effects.append(.requestOpened(request))

        case "PostToolUse", "PostToolUseFailure":
            if let id = ev.toolUseId, let i = s.running.firstIndex(where: { $0.toolUseId == id }) {
                s.running.remove(at: i)
            } else if let i = s.running.lastIndex(where: { $0.toolName == ev.toolName }) {
                s.running.remove(at: i)
            }
            if ev.isInterrupt == true {
                effects += closeAll(&s)
                s.running = []
                s.status = .idle
                s.currentAction = "Прервано"
            } else {
                // Запрос закрываем по tool_use_id; без него — только запрос, которому id не удалось привязать,
                // и только по имени инструмента. Завершившийся вызов без запроса чужую карточку не трогает.
                let index = s.queue.firstIndex { $0.toolUseId != nil && $0.toolUseId == ev.toolUseId }
                    ?? s.queue.firstIndex { $0.toolUseId == nil && $0.toolName == ev.toolName }
                if let i = index {
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
            s.running = []
            s.currentAction = ""
            refreshBranch(&s)
            effects.append(.sessionBecameDone(sessionId: s.sessionId))

        case "StopFailure":
            effects += closeAll(&s)
            s.status = .idle
            s.running = []
            s.currentAction = "Ошибка API"

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

    /// Сессия «работает», а событий нет:
    /// - инструментов нет и тишина дольше `quietAfter` → «простаивает»;
    /// - идут только `Bash`, тишина дольше `staleToolAfter` и у процесса сессии нет дочерних процессов
    ///   (команду прервали клавишей Esc: события об этом Claude Code не присылает) → «простаивает»;
    /// - идут другие инструменты, тишина дольше `quietAfter` → «простаивает».
    @discardableResult
    public mutating func sweepQuiet(
        now: Date,
        quietAfter: TimeInterval = 600,
        staleToolAfter: TimeInterval = 20,
        hasChildProcess: (Session) -> Bool = { _ in true }
    ) -> [String] {
        var changed: [String] = []
        for (id, var s) in sessions where s.status == .working {
            let quiet = now.timeIntervalSince(s.lastEventAt)
            let stale: Bool
            if s.running.isEmpty {
                stale = quiet > quietAfter
            } else if s.running.allSatisfy({ $0.toolName == "Bash" }) {
                stale = quiet > staleToolAfter && !hasChildProcess(s)
            } else {
                stale = quiet > quietAfter
            }
            if stale {
                s.status = .idle
                s.running = []
                s.currentAction = ""
                sessions[id] = s
                changed.append(id)
            }
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

    /// Тот же ли процесс; если pid или время старта неизвестны (0 / nil), считаем, что тот же.
    static func sameProcess(_ s: Session, _ msg: BridgeMessage) -> Bool {
        if s.pid <= 0 || msg.pid <= 0 { return true }
        if s.pid != msg.pid { return false }
        guard let a = s.processStartedAt, let b = msg.processStartedAt else { return true }
        return abs(a - b) < 2
    }

    static func sameStart(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 2
    }

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
            tty: msg.tty,
            hints: msg.hints,
            permissionMode: msg.event.permissionMode,
            firstSeenAt: now,
            lastEventAt: now,
            running: [],
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
Expected: PASS — `Executed 28 tests, with 0 failures`

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

Живость сессии проверяется парой «pid + время старта»: тот же pid с другим временем старта — это уже чужой процесс (pid переиспользован). Поиск процесса сессии принимает условие по имени, потому что на этой машине встречаются оба имени: `claude` и `claude.exe`.

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

    /// Терминальное устройство процесса («ttys003»); nil, если у процесса нет терминала.
    public static func ttyName(of pid: Int32) -> String? {
        guard let i = info(pid: pid) else { return nil }
        let dev = i.kp_eproc.e_tdev
        guard dev != -1, let c = devname(dev, mode_t(S_IFCHR)) else { return nil }
        return String(cString: c)
    }

    /// Процесс жив и это тот же процесс (время старта совпадает), а не переиспользованный pid.
    public static func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        guard let started = startTime(pid: pid) else { return false }
        guard let startedAt else { return true }
        return abs(started - startedAt) < 2
    }

    /// Первый предок (включая сам `pid`), чьё имя подходит под условие.
    public static func ancestorPid(matching isMatch: (String) -> Bool, from pid: Int32, maxDepth: Int = 8) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            if let n = name(of: current), isMatch(n) { return current }
            guard let parent = parentPid(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Дочерние процессы (по таблице процессов; для интервала в секунды этого достаточно).
    public static func childPids(of pid: Int32) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var bytes = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &buffer, &bytes, nil, 0) == 0 else { return [] }
        return buffer.prefix(bytes / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_ppid == pid }
            .map { $0.kp_proc.p_pid }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter ProcessProbeTests`
Expected: PASS — `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/ProcessProbe.swift Tests/TopbarCoreTests/ProcessProbeTests.swift
git commit -m "feat(core): process start time, parent, name, tty, children and liveness"
```

---

### Task 5: Сокет и логика моста

**Files:**
- Create: `Sources/TopbarCore/Sockets.swift`, `Sources/TopbarCore/BridgeRunner.swift`
- Test: `Tests/TopbarCoreTests/BridgeSocketTests.swift`

Закрепляемые правила спеки: нет сокета — мост молча выходит быстро; подключение, запись и «принято» укладываются в один срок 0,3 с, в том числе при зависшем получателе и большом событии; решение `allow`/`deny` печатается в формате хука; `none` и остановка сервера освобождают мост сразу, а не по тайм-ауту; полный ввод уходит только вместе с запросом разрешения; номер процесса неизвестен → 0, а не родитель; права каталога и сокета только для владельца; живой слушатель не перехватывается, чужой файл при остановке не удаляется; ядро узнаёт, что мост отключился.

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
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `cannot find 'BridgeRunner' in scope`.

- [ ] **Step 3: Реализовать сокет и мост**

**Create:** `Sources/TopbarCore/Sockets.swift`

```swift
import Foundation
import Darwin

public enum SocketError: Error, Equatable { case pathTooLong, alreadyRunning, system(String) }

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
    /// Соединение остаётся неблокирующим: все чтения и записи идут через `poll` с дедлайном.
    public static func connect(path: String, timeout: Double) -> Int32? {
        guard var addr = try? makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setNoSigPipe(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withSockaddr(&addr) { Darwin.connect(fd, $0, $1) }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(max(0, timeout) * 1000)) > 0 else { close(fd); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { close(fd); return nil }
        }
        return fd
    }

    /// Записать всё до дедлайна. false — не успели (получатель завис) или соединение разорвано.
    public static func writeAll(_ fd: Int32, _ data: Data, deadline: Date = Date().addingTimeInterval(1)) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buf -> Bool in
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max))))
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
            if n == 0 { return nil }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return nil
            }
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

    /// true — ответ записан в соединение (получатель мог уже закрыться, но запись не упала).
    @discardableResult
    public func send(_ reply: CoreReply) -> Bool {
        guard !closed, let data = try? Wire.encode(reply) else { return false }
        return SocketClient.writeAll(fd, data)
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
    private var ownedInode: UInt64?
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
        chmod(dir, 0o700) // каталог мог уже существовать с другими правами
        // Живой слушатель на этом пути — не перехватываем его сокет.
        if let probe = SocketClient.connect(path: path, timeout: 0.2) {
            close(probe)
            throw SocketError.alreadyRunning
        }
        unlink(path)
        var addr = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket: \(errno)") }
        guard withSockaddr(&addr, { Darwin.bind(fd, $0, $1) }) == 0 else {
            close(fd); throw SocketError.system("bind: \(errno)")
        }
        chmod(path, 0o600)
        var st = stat()
        if stat(path, &st) == 0 { ownedInode = UInt64(st.st_ino) }
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
            // Удаляем только свой файл: если путь уже занял другой экземпляр, его сокет не трогаем.
            var st = stat()
            if let owned = ownedInode, stat(path, &st) == 0, UInt64(st.st_ino) == owned { unlink(path) }
            ownedInode = nil
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
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter BridgeSocketTests`
Expected: PASS — `Executed 17 tests, with 0 failures`

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

Записи topbar узнаются по метке `# topbar-managed` в команде, поэтому установка повторяема, а удаление не трогает чужие хуки. Путь к мосту содержит пробел («Application Support»), поэтому он берётся в кавычки. Установщик отказывается писать, если раздел хуков имеет неожиданный вид (чужое не затирается). Запись пересобирает файл: ключи сортируются, отступы унифицируются — `willReformat` сообщает об этом, `diff` показывает построчную разницу с реальным содержимым файла. Копий файла рядом не создаём (правило владельца): запись атомарная, сохраняет права и симлинк (это делает консоль в задаче 8).

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

    public enum InstallError: Error, Equatable {
        case notAnObject
        /// Значение хуков события имеет неожиданный вид; файл не трогаем, чтобы не затереть чужое.
        case unexpectedShape(String)
    }

    public static func command(bridgePath: String) -> String {
        let quoted = "'" + bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(marker)"
    }

    public static func install(into data: Data?, bridgePath: String) throws -> Data {
        var root = try parse(data)
        var hooks = try hooksObject(root)
        for (name, timeout) in events {
            var groups = try groups(hooks, name).compactMap(strippingManaged)
            groups.append(["hooks": [["type": "command", "command": command(bridgePath: bridgePath), "timeout": timeout]]])
            hooks[name] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func remove(from data: Data) throws -> Data {
        var root = try parse(data)
        guard var hooks = try hooksObjectIfAny(root) else { return try serialize(root) }
        for name in Array(hooks.keys) {
            let remaining = try groups(hooks, name).compactMap(strippingManaged)
            hooks[name] = remaining.isEmpty ? nil : remaining
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

    /// Пути моста, на которые ссылаются хуки topbar (для проверки, что файл ещё существует).
    public static func bridgePaths(in data: Data?) -> Set<String> {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return [] }
        var result = Set<String>()
        for value in hooks.values {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] where isManaged(hook) {
                    if let command = hook["command"] as? String, let path = unquotedPath(command) { result.insert(path) }
                }
            }
        }
        return result
    }

    /// Построчная разница «как в файле сейчас → как будет записано».
    public static func diff(old: Data?, new: Data) -> String {
        let oldLines = old.map(lines) ?? []
        var out: [String] = []
        for change in lines(new).difference(from: oldLines) {
            switch change {
            case .insert(_, let line, _): out.append("+ " + line)
            case .remove(_, let line, _): out.append("- " + line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Запись пересоберёт файл (отсортирует ключи, изменит отступы), даже если хуки не менялись.
    public static func willReformat(_ old: Data?) -> Bool {
        guard let old, !old.isEmpty, let root = try? parse(old), let normal = try? serialize(root) else { return false }
        return normal != old
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

    private static func hooksObjectIfAny(_ root: [String: Any]) throws -> [String: Any]? {
        guard let value = root["hooks"] else { return nil }
        guard let hooks = value as? [String: Any] else { throw InstallError.unexpectedShape("hooks") }
        return hooks
    }

    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        try hooksObjectIfAny(root) ?? [:]
    }

    private static func groups(_ hooks: [String: Any], _ name: String) throws -> [[String: Any]] {
        guard let value = hooks[name] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw InstallError.unexpectedShape(name) }
        return groups
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

    /// Путь из команды вида `'/путь с пробелами/topbar-hook' # topbar-managed`.
    private static func unquotedPath(_ command: String) -> String? {
        guard command.hasPrefix("'"), let end = command.range(of: "' ", range: command.index(after: command.startIndex)..<command.endIndex)
        else { return nil }
        let inner = command[command.index(after: command.startIndex)..<end.lowerBound]
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter HookInstallerTests`
Expected: PASS — `Executed 10 tests, with 0 failures`

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

`SessionHub` — то, что часть 2 подключит к окну острова. Колбэки идут на отдельную очередь (интерфейс подставит главную), поэтому из них безопасно вызывать `snapshot()`, `decide()` и прочее. Закрепляемые правила: решение с карточки доходит до моста (и отказ с текстом); ответ в терминале (`PostToolUse`) закрывает карточку и освобождает мост; запоздалое решение сообщает «не доставлено»; при `autoOpenPolicy == false` остров не раскрывается, но канал держится и ответить можно по идентификатору из снимка; отключившийся мост закрывает карточку; дубль идентификатора не крадёт чужой канал; `releaseAllCards` освобождает мосты без смены статуса; вопросы без кнопок показываются «ждёт» без карточки; сессии без терминала не видны вовсе; исчезнувший процесс убирает сессию, а сессия с неизвестным процессом не убирается; прервавшаяся команда без дочерних процессов сбрасывается.

- [ ] **Step 1: Написать тесты**

**Create:** `Tests/TopbarCoreTests/SessionHubTests.swift`

```swift
import XCTest
@testable import TopbarCore

final class SessionHubTests: XCTestCase {
    func hook(_ name: String, sid: String = "s1", tool: String? = nil, input: [String: Any] = ["command": "mkdir x"],
              extra: [String: Any] = [:]) -> Data {
        var d: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": "/work/topbar", "permission_mode": "default"]
        if let tool { d["tool_name"] = tool; d["tool_input"] = input }
        extra.forEach { d[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    func bridge(_ data: Data, path: String, env: [String: String] = [:], decision: Double = 5) -> Data? {
        // Живой процесс сессии — сам тест: так проверка живости не уберёт сессию.
        var environment = ["CLAUDE_PID": "\(getpid())"]
        env.forEach { environment[$0.key] = $0.value }
        return BridgeRunner.run(stdin: data, environment: environment, parentPid: 1,
                                socketPath: path, decisionTimeout: decision)
    }

    func makeHub(path: String) -> SessionHub {
        SessionHub(socketPath: path, livenessInterval: 3600, branchProvider: { _ in "main" })
    }

    /// Запрос разрешения в фоне: возвращает «ответ моста» через expectation.
    func requestInBackground(_ path: String, tool: String = "Bash", sid: String = "s1",
                             env: [String: String] = [:], timeout: Double = 20) -> (done: XCTestExpectation, output: () -> Data??) {
        let done = expectation(description: "bridge finished")
        var result: Data?? = .none
        DispatchQueue.global().async {
            result = .some(self.bridge(self.hook("PermissionRequest", sid: sid, tool: tool), path: path, env: env, decision: timeout))
            done.fulfill()
        }
        return (done, { result })
    }

    func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    }

    func decision(_ data: Data?) -> String? {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specific = obj["hookSpecificOutput"] as? [String: Any],
              let d = specific["decision"] as? [String: Any] else { return nil }
        return d["behavior"] as? String
    }

    // MARK: решения и закрытие карточек

    func testCardDecisionReachesBridgeAsAllow() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.onRequestOpened = { req, _ in hub.decide(requestId: req.requestId, allow: true) }
        try hub.start()
        defer { hub.stop() }

        _ = bridge(hook("UserPromptSubmit"), path: path)
        let out = bridge(hook("PermissionRequest", tool: "Bash"), path: path)
        XCTAssertEqual(decision(out), "allow")
        hub.flush()
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testDenyReachesBridgeWithMessage() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.onRequestOpened = { req, _ in hub.decide(requestId: req.requestId, allow: false, denyMessage: "нельзя") }
        try hub.start()
        defer { hub.stop() }
        let out = bridge(hook("PermissionRequest", tool: "Bash"), path: path)
        XCTAssertEqual(decision(out), "deny")
        XCTAssertTrue(String(decoding: out ?? Data(), as: UTF8.self).contains("нельзя"))
    }

    func testPostToolUseClosesCardAndReleasesBridge() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let closed = expectation(description: "closed")
        hub.onRequestClosed = { _ in closed.fulfill() }
        try hub.start()
        defer { hub.stop() }

        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.status == .waitingPermission }
        // Владелец ответил в терминале: приходит PostToolUse.
        _ = bridge(hook("PostToolUse", tool: "Bash"), path: path)
        wait(for: [closed, pending.done], timeout: 3)
        XCTAssertEqual(pending.output(), .some(nil), "мост выходит без решения")
        XCTAssertEqual(hub.snapshot().first?.status, .working)
    }

    func testDecideAfterTerminalAnswerIsReportedAsNotDelivered() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var requestId: String?
        let opened = expectation(description: "opened")
        hub.onRequestOpened = { r, _ in requestId = r.requestId; opened.fulfill() }
        try hub.start()
        defer { hub.stop() }
        let pending = requestInBackground(path)
        wait(for: [opened], timeout: 2)
        _ = bridge(hook("PostToolUse", tool: "Bash"), path: path)
        wait(for: [pending.done], timeout: 3)

        let reported = expectation(description: "completion")
        hub.decide(requestId: requestId!, allow: true) { delivered in
            XCTAssertFalse(delivered)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 2)
    }

    func testAutoOpenPolicyFalseKeepsChannelSoRowClickCanStillDecide() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        hub.autoOpenPolicy = { _, _ in false }   // владелец смотрит на сессию
        var autoOpened = false
        hub.onRequestOpened = { _, _ in autoOpened = true }
        try hub.start()
        defer { hub.stop() }

        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.queue.isEmpty == false }
        hub.flush()
        XCTAssertFalse(autoOpened, "остров не раскрывается сам")
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission)
        // Клик по строке: карточку открывают вручную и отвечают по идентификатору из снимка.
        let id = try XCTUnwrap(hub.snapshot().first?.queue.first?.requestId)
        hub.decide(requestId: id, allow: true)
        wait(for: [pending.done], timeout: 3)
        XCTAssertEqual(decision(pending.output() ?? nil), "allow")
    }

    func testBridgeDisconnectClosesCard() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let opened = expectation(description: "opened")
        let closed = expectation(description: "closed")
        hub.onRequestOpened = { _, _ in opened.fulfill() }
        hub.onRequestClosed = { _ in closed.fulfill() }
        try hub.start()
        defer { hub.stop() }

        let fd = try XCTUnwrap(SocketClient.connect(path: path, timeout: 1))
        let msg = BridgeMessage(requestId: "dead-bridge", event: HookEvent("PermissionRequest", sessionId: "s1", cwd: "/work/topbar", toolName: "Bash", toolInput: Fx.bash("ls")), pid: getpid())
        XCTAssertTrue(SocketClient.writeAll(fd, try Wire.encode(msg)))
        XCTAssertNotNil(SocketClient.readLine(fd, timeout: 1))
        wait(for: [opened], timeout: 2)
        close(fd) // хук истёк или мост убит
        wait(for: [closed], timeout: 2)
    }

    func testDuplicateRequestIdIsRejectedWithoutStealingChannel() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let opened = expectation(description: "opened")
        hub.onRequestOpened = { _, _ in opened.fulfill() }
        try hub.start()
        defer { hub.stop() }

        func send(_ id: String) throws -> Int32 {
            let fd = try XCTUnwrap(SocketClient.connect(path: path, timeout: 1))
            let msg = BridgeMessage(requestId: id, event: HookEvent("PermissionRequest", sessionId: "s1", cwd: "/work/topbar", toolName: "Bash", toolInput: Fx.bash("ls")), pid: getpid())
            XCTAssertTrue(SocketClient.writeAll(fd, try Wire.encode(msg)))
            XCTAssertNotNil(SocketClient.readLine(fd, timeout: 1)) // ack
            return fd
        }
        let first = try send("same-id")
        wait(for: [opened], timeout: 2)
        let second = try send("same-id")
        let reply = try XCTUnwrap(SocketClient.readLine(second, timeout: 1))
        XCTAssertEqual(try Wire.decode(CoreReply.self, line: reply).kind, .none)
        close(second)

        hub.decide(requestId: "same-id", allow: true)
        let answer = try XCTUnwrap(SocketClient.readLine(first, timeout: 2))
        XCTAssertEqual(try Wire.decode(CoreReply.self, line: answer).behavior, "allow")
        close(first)
    }

    func testReleaseAllCardsFreesBridgesButKeepsStatus() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        try hub.start()
        defer { hub.stop() }
        let pending = requestInBackground(path)
        waitUntil { hub.snapshot().first?.status == .waitingPermission }
        hub.releaseAllCards()
        wait(for: [pending.done], timeout: 3)
        XCTAssertEqual(pending.output(), .some(nil))
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission, "диалог остался в терминале")
    }

    // MARK: что не показываем карточкой

    func testQuestionToolWaitsWithoutCardAndReleasesBridge() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var opened = 0
        hub.onRequestOpened = { _, _ in opened += 1 }
        try hub.start()
        defer { hub.stop() }
        XCTAssertNil(bridge(hook("PermissionRequest", tool: "AskUserQuestion"), path: path))
        hub.flush()
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(hub.snapshot().first?.status, .waitingPermission, "сессия ждёт вас, просто без кнопок")
    }

    func testUnattendedSessionsAreIgnoredCompletely() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        var done = 0
        hub.onSessionDone = { _ in done += 1 }
        try hub.start()
        defer { hub.stop() }
        let env = ["CLAUDE_CODE_SESSION_ATTENDED": "0"]
        _ = bridge(hook("UserPromptSubmit", sid: "bg"), path: path, env: env)
        XCTAssertNil(bridge(hook("PermissionRequest", sid: "bg", tool: "Bash"), path: path, env: env))
        _ = bridge(hook("Stop", sid: "bg"), path: path, env: env)
        hub.flush()
        XCTAssertTrue(hub.snapshot().isEmpty, "ни строки, ни звука")
        XCTAssertEqual(done, 0)
    }

    // MARK: прочее

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
        hub.flush()
        XCTAssertEqual(hub.snapshot().first?.status, .idle)
    }

    func testCallbacksMayCallBackIntoHubWithoutDeadlock() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        let called = expectation(description: "onChange")
        called.assertForOverFulfill = false
        hub.onChange = { _ in
            _ = hub.snapshot()
            hub.markViewed(sessionId: "s1")
            called.fulfill()
        }
        try hub.start()
        defer { hub.stop() }
        _ = bridge(hook("UserPromptSubmit"), path: path)
        wait(for: [called], timeout: 2)
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

    func testSessionWithUnknownPidIsNeverRemovedByLiveness() throws {
        let path = Fx.socketPath()
        let hub = makeHub(path: path)
        try hub.start()
        defer { hub.stop() }
        // CLAUDE_PID не передан, предка claude нет → pid 0.
        _ = BridgeRunner.run(stdin: hook("UserPromptSubmit"), environment: [:], parentPid: 1, socketPath: path)
        hub.tickNow()
        XCTAssertEqual(hub.snapshot().count, 1)
    }

    func testBashWithoutChildProcessesIsDroppedByTickButLiveOneIsKept() throws {
        for (hasChildren, expected) in [(false, SessionStatus.idle), (true, SessionStatus.working)] {
            let path = Fx.socketPath()
            let hub = SessionHub(socketPath: path, livenessInterval: 3600, staleToolAfter: 0,
                                 branchProvider: { _ in nil }, hasChildProcess: { _ in hasChildren })
            try hub.start()
            defer { hub.stop() }
            _ = bridge(hook("PreToolUse", tool: "Bash"), path: path)
            XCTAssertEqual(hub.snapshot().first?.status, .working)
            Thread.sleep(forTimeInterval: 0.05)
            hub.tickNow()
            XCTAssertEqual(hub.snapshot().first?.status, expected, "дочерние процессы: \(hasChildren)")
        }
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

/// Склеивает сокет, автомат статусов и проверку живости.
/// Внутренняя работа идёт на `queue`; все колбэки уходят на отдельную очередь `callbackQueue`
/// (интерфейс подставит главную), поэтому из колбэка безопасно вызывать `snapshot()`, `decide()` и т. д.
public final class SessionHub {
    public let queue = DispatchQueue(label: "topbar.hub")
    public let callbackQueue: DispatchQueue

    /// Раскрывать ли остров сам по этому запросу. false (владелец смотрит на сессию, нет экрана) —
    /// запрос всё равно остаётся в сессии, и карточку можно открыть вручную: канал к мосту держится.
    public var autoOpenPolicy: (Session, PermissionRequest) -> Bool = { _, _ in true }
    public var onChange: (([Session]) -> Void)?
    /// Появился запрос, который нужно показать карточкой (вопросы вроде `AskUserQuestion` сюда не попадают).
    public var onRequestOpened: ((PermissionRequest, Session) -> Void)?
    /// Запрос закрыт (ответили в терминале, сессия закончилась, мост отключился): карточку убрать.
    public var onRequestClosed: ((String) -> Void)?
    public var onSessionDone: ((Session) -> Void)?
    /// Каждое принятое событие (для диагностики).
    public var onEvent: ((BridgeMessage) -> Void)?

    private var store: SessionStore
    private var server: SocketServer!
    private var channels: [String: ReplyChannel] = [:]
    private var timer: DispatchSourceTimer?
    private let livenessInterval: TimeInterval
    private let hasChildProcess: (Session) -> Bool
    private let staleToolAfter: TimeInterval

    public init(
        socketPath: String,
        livenessInterval: TimeInterval = 10,
        staleToolAfter: TimeInterval = 20,
        callbackQueue: DispatchQueue = DispatchQueue(label: "topbar.hub.callbacks"),
        branchProvider: @escaping (String) -> String? = BranchReader.branch(at:),
        hasChildProcess: @escaping (Session) -> Bool = { $0.pid <= 0 || !ProcessProbe.childPids(of: $0.pid).isEmpty }
    ) {
        self.store = SessionStore(branchProvider: branchProvider)
        self.livenessInterval = livenessInterval
        self.staleToolAfter = staleToolAfter
        self.callbackQueue = callbackQueue
        self.hasChildProcess = hasChildProcess
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

    /// Ответ владельца с карточки. `completion(true)` — решение доставлено мосту;
    /// `false` — запрос уже закрыт (ответили в терминале) или мост ушёл. Вызывается на `callbackQueue`.
    public func decide(
        requestId: String,
        allow: Bool,
        denyMessage: String = "Отклонено в topbar",
        completion: ((Bool) -> Void)? = nil
    ) {
        queue.async { [self] in
            guard let channel = channels.removeValue(forKey: requestId) else {
                emit { completion?(false) }
                return
            }
            let delivered = channel.send(allow ? .allow() : .deny(denyMessage))
            if delivered {
                store.resolve(requestId: requestId)
                notifyChange()
            } else {
                emit { self.onRequestClosed?(requestId) }
            }
            emit { completion?(delivered) }
        }
    }

    /// Закрыть все карточки без решения (сон, закрытая крышка, пропал экран с вырезом):
    /// диалоги остаются в терминалах, статусы сессий не меняются.
    public func releaseAllCards() {
        queue.async { [self] in
            let ids = Array(channels.keys)
            for (_, channel) in channels { channel.send(.none) }
            channels = [:]
            for id in ids { emit { self.onRequestClosed?(id) } }
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

    /// Для тестов: дождаться, пока обработаны очередь хаба и уже поставленные колбэки.
    public func flush() {
        queue.sync {}
        callbackQueue.sync {}
    }

    // MARK: внутреннее (всё на queue)

    private func emit(_ block: @escaping () -> Void) { callbackQueue.async(execute: block) }

    private func handle(_ msg: BridgeMessage, _ channel: ReplyChannel) {
        channel.send(.ack)
        let ev = msg.event
        let isRequest = ev.hookEventName == "PermissionRequest"
        emit { self.onEvent?(msg) }

        // Сессии без терминала (`claude -p`, SDK, cron) не показываем вовсе: ни строк, ни звука,
        // а запрос остаётся за Claude Code.
        if msg.unattended {
            if isRequest { channel.send(.none) }
            return
        }
        // Идентификатор выбирает мост; дубль не должен затирать чужой канал.
        if isRequest && channels[msg.requestId] != nil {
            channel.send(.none)
            return
        }

        let effects = store.apply(msg, now: Date())

        var opened: (PermissionRequest, Session)?
        if isRequest {
            if let session = store.sessions[ev.sessionId],
               let request = session.queue.first(where: { $0.requestId == msg.requestId }),
               request.cardable {
                channels[request.requestId] = channel
                channel.onClose = { [weak self] in self?.channelClosed(request.requestId) }
                if autoOpenPolicy(session, request) { opened = (request, session) }
            } else {
                channel.send(.none) // вопрос без кнопок или запрос не попал в автомат
            }
        }

        for effect in effects {
            switch effect {
            case .requestClosed(let id):
                channels.removeValue(forKey: id)?.send(.none)
                emit { self.onRequestClosed?(id) }
            case .sessionBecameDone(let id):
                if let s = store.sessions[id] { emit { self.onSessionDone?(s) } }
            case .requestOpened, .sessionRemoved:
                break
            }
        }
        if let (request, session) = opened { emit { self.onRequestOpened?(request, session) } }
        notifyChange()
    }

    /// Мост отключился (хук истёк, процесс убит): кнопки на карточке уже бесполезны.
    private func channelClosed(_ requestId: String) {
        guard channels.removeValue(forKey: requestId) != nil else { return }
        emit { self.onRequestClosed?(requestId) }
    }

    private func tick() {
        var changed = false
        for s in store.sessions.values where s.pid > 0 && !ProcessProbe.isAlive(pid: s.pid, startedAt: s.processStartedAt) {
            for effect in store.remove(sessionId: s.sessionId) {
                if case .requestClosed(let id) = effect {
                    channels.removeValue(forKey: id)?.send(.none)
                    emit { self.onRequestClosed?(id) }
                }
            }
            changed = true
        }
        if !store.sweepQuiet(now: Date(), staleToolAfter: staleToolAfter, hasChildProcess: hasChildProcess).isEmpty { changed = true }
        if changed { notifyChange() }
    }

    private func notifyChange() {
        let sessions = store.snapshot()
        emit { self.onChange?(sessions) }
    }
}
```

- [ ] **Step 4: Прогнать весь набор три раза подряд (тесты используют потоки и время)**

Run: `for i in 1 2 3; do swift test 2>&1 | grep -E "error:|failed|Executed 87"; done | sort | uniq -c`
Expected: только строки `Executed 87 tests, with 0 failures`, без `error:` и `failed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/TopbarCore/SessionHub.swift Tests/TopbarCoreTests/SessionHubTests.swift
git commit -m "feat(core): session hub wiring socket, store and liveness"
```

---

### Task 8: Мост и консоль разработчика

**Files:**
- Modify: `Sources/topbar-hook/main.swift`, `Sources/topbar-dev/main.swift` (заменить заглушки)

Исполняемые файлы только вызывают проверенную логику из `TopbarCore`, поэтому своих юнит-тестов у них нет: их проверяет задача 9. Консоль печатает ввод запроса **целиком**, показывает субагента, сообщает «не доставлено» вместо ложного «разрешено», сохраняет симлинк и права `settings.json` при записи и предупреждает о переформатировании файла.

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
    topbar-dev run [--verbose]
        слушать хуки и показывать сессии; на запрос разрешения отвечать y (разрешить) или n (отклонить);
        --verbose печатает каждое событие (есть ли tool_use_id, терминал, признаки окна)
    topbar-dev install-bridge --from <путь к topbar-hook>
        скопировать мост в стабильное место
    topbar-dev install --settings <settings.json> [--yes]
        показать, что изменится в файле, и вписать хуки
    topbar-dev uninstall --settings <settings.json>
        убрать хуки topbar
    topbar-dev status --settings <settings.json>
        установлены ли хуки и существует ли мост, на который они ссылаются
    """)
    exit(2)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Запись в settings.json: симлинк сохраняется (пишем в его цель), права файла сохраняются.
func writeSettings(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
    try data.write(to: url, options: .atomic)
    if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "run":
    let verbose = args.contains("--verbose")
    let hub = SessionHub(socketPath: Paths.socketPath)
    var open: [PermissionRequest] = []   // трогаем только на hub.callbackQueue
    let out = hub.callbackQueue

    hub.onRequestOpened = { request, session in
        open.append(request)
        let agent = request.agentType.map { " (субагент \($0))" } ?? ""
        print("\n? [\(session.project)]\(agent) \(request.toolName):\n\(request.detail)\n  ответ: y — разрешить, n — отклонить")
        fflush(stdout)
    }
    hub.onRequestClosed = { id in
        open.removeAll { $0.requestId == id }
        print("  (запрос закрыт: \(id.prefix(6)))")
    }
    hub.onSessionDone = { session in
        print("\u{7}✓ готово: \(session.project)")
    }
    hub.onEvent = { msg in
        guard verbose else { return }
        let e = msg.event
        print("  · \(e.hookEventName) tool=\(e.toolName ?? "-") tool_use_id=\(e.toolUseId ?? "нет") pid=\(msg.pid) tty=\(msg.tty ?? "-") term=\(msg.termProgram ?? "-") unattended=\(msg.unattended) hints=\(msg.hints)")
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
    do { try hub.start() } catch SocketError.alreadyRunning {
        fail("сокет \(Paths.socketPath) уже слушает другой экземпляр")
    } catch { fail("не удалось открыть сокет \(Paths.socketPath): \(error)") }
    print("слушаю \(Paths.socketPath)")

    Thread.detachNewThread {
        while let line = readLine() {
            let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "n" else { continue }
            out.async {
                guard let request = open.first else { print("  (нет открытых запросов)"); return }
                open.removeFirst()
                hub.decide(requestId: request.requestId, allow: answer == "y") { delivered in
                    print(delivered
                        ? "  → \(answer == "y" ? "разрешено" : "отклонено"): \(request.summary)"
                        : "  → не доставлено (запрос уже закрыт): \(request.summary)")
                }
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
    let old = FileManager.default.contents(atPath: URL(fileURLWithPath: settings).resolvingSymlinksInPath().path)
    do {
        switch command {
        case "status":
            guard HookInstaller.isInstalled(in: old) else { print("хуки не установлены"); break }
            print("хуки установлены")
            for path in HookInstaller.bridgePaths(in: old).sorted() {
                let exists = FileManager.default.isExecutableFile(atPath: path)
                print(exists ? "  мост на месте: \(path)" : "  ВНИМАНИЕ: моста нет по пути \(path) — каждое событие будет падать с ошибкой")
            }
        case "install":
            guard FileManager.default.isExecutableFile(atPath: Paths.bridgeInstallPath) else {
                fail("сначала: topbar-dev install-bridge --from <путь к topbar-hook>")
            }
            let new = try HookInstaller.install(into: old, bridgePath: Paths.bridgeInstallPath)
            if HookInstaller.willReformat(old) {
                print("ВНИМАНИЕ: файл будет переформатирован — ключи отсортируются, отступы станут единообразными.")
            }
            print(HookInstaller.diff(old: old, new: new))
            if !args.contains("--yes") {
                print("\nЗаписать в \(settings)? [y/N] ", terminator: "")
                guard readLine()?.lowercased() == "y" else { print("отменено"); exit(0) }
            }
            try writeSettings(new, to: settings)
            print("хуки вписаны")
        default:
            guard let old else { fail("нет файла \(settings)") }
            let new = try HookInstaller.remove(from: old)
            try writeSettings(new, to: settings)
            print("хуки убраны")
        }
    } catch HookInstaller.InstallError.unexpectedShape(let key) {
        fail("в файле неожиданный вид раздела «\(key)»; ничего не изменено")
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

**Files:** изменений в коде нет, если всё сходится; результаты записываются в спеку (шаг 10).

Эту задачу выполняют вместе с владельцем: нужны живые интерактивные сессии. Хуки вписываются **только** в настройки временной папки (они действуют лишь в сессиях, запущенных из неё); глобальный `~/.claude/settings.json` не трогается. Вне проекта и вне временной папки пишутся только: каталог данных приложения `~/Library/Application Support/topbar/` (сокет и копия моста: так задумано спекой) и служебные записи самого Claude Code о запущенных там сессиях и доверии к папке (`~/.claude/projects/…`, `~/.claude.json`): их Claude Code создаёт для любой папки, они остаются после уборки и безвредны.

- [ ] **Step 1: Собрать мост и консоль, установить мост в стабильное место**

Run:
```bash
swift build -c release --product topbar-hook && swift build --product topbar-dev
.build/debug/topbar-dev install-bridge --from .build/release/topbar-hook
```
Expected: `мост установлен: /Users/yer6o/Library/Application Support/topbar/bin/topbar-hook`.

- [ ] **Step 2: Создать временную папку и вписать хуки только в неё**

Run:
```bash
E2E=$(mktemp -d /tmp/topbar-e2e.XXXXXX); echo "$E2E"
mkdir -p "$E2E/.claude" && echo '{}' > "$E2E/.claude/settings.json"
.build/debug/topbar-dev install --settings "$E2E/.claude/settings.json"
```
Expected: показаны строки со знаком `+` (в том числе `topbar-managed`), вопрос `Записать …? [y/N]` — ответить `y`. Затем `.build/debug/topbar-dev status --settings "$E2E/.claude/settings.json"` → `хуки установлены` и `мост на месте: …`. Запомнить путь `$E2E` (дальше он нужен в каждом окне).

- [ ] **Step 3: Запустить консоль в окне Ghostty №1**

Run: `.build/debug/topbar-dev run --verbose`
Expected: `слушаю /Users/yer6o/Library/Application Support/topbar/hook.sock`. С флагом `--verbose` каждая строка `· <событие> …` показывает, есть ли `tool_use_id`, номер процесса, терминал, `unattended` и признаки окна.

- [ ] **Step 4: Открыть сессию в окне Ghostty №2**

Run: `cd "$E2E" && claude --permission-mode default`
При первом запуске Claude Code спросит про доверие к папке — принять, затем **завершить сессию (`/exit`) и запустить заново той же командой**: хуки папки подхватываются полноценно только после принятия доверия.

- [ ] **Step 5: Пройти сценарии и записать для каждого «как ожидалось / иначе (что именно)»**

| № | Действие | Ожидаемое |
| :- | :- | :- |
| a | Открыть сессию | В консоли строка `простаивает  <папка>  [Ghostty]`; в `--verbose` у `SessionStart` записать `tty=`, `term=` и ключи `hints=` (понадобятся для поиска окна в части 2) |
| b | Написать `выполни команду mkdir probe-a`, в консоли нажать `y` | `работает`, затем `? […] Bash:` с полным текстом команды; после `y` диалог в окне №2 закрывается сам, команда выполняется, `✓ готово` со звонком. **Записать: есть ли `tool_use_id=…` у `PreToolUse` и `PostToolUse` (не «нет»)** |
| c | `выполни команду mkdir probe-b`, ответить **в окне №2** | В консоли `(запрос закрыт: …)` в течение 1–2 с, статус возвращается в `работает`, потом `готово` |
| d | `выполни команду mkdir probe-c`, в консоли нажать `n` | Claude сообщает об отказе с текстом «Отклонено в topbar» |
| e | Разрешение **в терминале** на долгой команде: `выполни команду sleep 20 && echo ok`, ответить «да» в окне №2 | Записать, когда закрылся запрос в консоли: сразу или только по окончании команды (~20 с). Это известное ограничение, оно должно совпасть с описанным в спеке |
| f | Отказ **в терминале**: `выполни команду mkdir probe-e`, ответить «нет» в окне №2, затем попросить любую другую команду | Записать, через сколько секунд запрос закрылся (ожидание: со следующим инструментом сессии, не раньше чем через 3 с) |
| g | Esc **во время команды**: `выполни команду sleep 120` (разрешить в терминале), через 5 с нажать Esc | Записать, какие события пришли (`--verbose`) и через сколько секунд статус стал `простаивает` (ожидание: 20–30 с) |
| h | Esc **пока Claude думает** (без инструмента): попросить длинное рассуждение и нажать Esc | Статус остаётся `работает` (известное ограничение до 10 минут) — подтвердить и записать, какие события пришли |
| i | В окне №3: `cd "$E2E" && claude -p "выполни mkdir probe-d" --permission-mode default` | В консоли **нет ни строки, ни карточки** по этой сессии; записать, чем закончился `claude -p` |
| j | Закрыть окно №2 крестиком при открытой сессии | Строка исчезает не позже ~10 с; записать, по `SessionEnd` (видно в `--verbose`) или по проверке живости |
| k | В новой сессии выполнить `/clear` | Остаётся одна строка (не две); записать, меняется ли идентификатор сессии |
| l | Запустить вторую сессию и убить её процесс (`kill -9 <pid из --verbose>`) | Строка исчезает не позже ~10 с |
| m | Две сессии в одной папке и ветке | Подписи различаются суффиксом `#2`; в сводке обе |
| n | Во время открытого запроса остановить консоль (Ctrl+C) | Диалог в терминале остаётся рабочим, сессия не зависла; после перезапуска консоли ответить в терминале — ошибок нет |
| o | Субагент: `запусти субагента, пусть он выполнит mkdir probe-f` | Записать: есть ли в карточке пометка «субагент …» (поля `agent_id` / `agent_type`) |

Любое расхождение, меняющее поведение, — сначала тест, воспроизводящий его, затем исправление кода (и обновление спеки), потом повтор пункта.

- [ ] **Step 6: Проверить признаки «без терминала» на интерактивной сессии**

Пункт b уже это проверяет: если в интерактивной сессии карточка (`?`) появилась, значит `CLAUDE_CODE_SESSION_ATTENDED` / `CLAUDE_CODE_ENTRYPOINT` не принимают её за «без терминала». Если карточки нет, переписать условие `unattended` в `Sources/TopbarCore/BridgeRunner.swift` по реальным значениям (временно залогировать окружение хука) и повторить пункт b.

- [ ] **Step 7: Повторить пункты a–c в терминале VS Code и в расширении Claude Code**

Открыть `$E2E` в VS Code, запустить `claude --permission-mode default` во встроенном терминале и пройти a, b, c. Затем, если расширение Claude Code для VS Code используется, пройти b в нём.
Expected: то же, но `[VS Code]`. Записать `term=` и ключи `hints=` и всё, что отличается; события из расширения могут не прийти — это тоже результат.

- [ ] **Step 8: Проверить скорость моста при выключенной консоли**

Остановить консоль (Ctrl+C), затем:

Run: `time (echo '{"hook_event_name":"Stop","session_id":"x"}' | "$HOME/Library/Application Support/topbar/bin/topbar-hook")`
Expected: завершается за доли секунды, без вывода и без ошибок (слушателя нет — мост молча выходит).

- [ ] **Step 9: Убрать за собой**

Run:
```bash
.build/debug/topbar-dev uninstall --settings "$E2E/.claude/settings.json"
rm -rf "$E2E"
```
Expected: `хуки убраны`. Каталог `~/Library/Application Support/topbar/` оставить: он понадобится приложению.

- [ ] **Step 10: Записать результаты в спеку и закоммитить всё**

Modify: `docs/specs/2026-11-03-topbar-mvp.md` — в разделе «Результаты опыта с хуками» добавить пункты по a–o и VS Code (что подтвердилось, что оказалось иначе), в «Открытых вопросах» закрыть 1-й частично (собраны `tty` и `hints`), 2–9-й полностью и дописать новые, если нашлись; в «Известных ограничениях» поправить цифры по фактическим замерам e–h.

```bash
swift test 2>&1 | grep -E "error:|failed|Executed"   # убедиться, что тесты по-прежнему зелёные
git add docs/specs Sources Tests
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
- `.build/debug/topbar-dev run --verbose` — слушать хуки и показывать сессии в терминале.

Установка хуков в настройки Claude Code — `topbar-dev install --settings <файл>` (показывает разницу и спрашивает подтверждение); убрать — `topbar-dev uninstall`.
```

- [ ] **Step 2: Полный прогон**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed" | tail -2`
Expected: актуальное число тестов (87 или больше, если в задаче 9 добавлялись), `0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add development notes to README"
```

- [ ] **Step 4: Отчёт владельцу и предложение интеграции**

Не мержить и не пушить самостоятельно: описать, что готово, чем проверено (тесты + таблица шага 5 задачи 9) и какие ограничения подтвердились, и предложить, как влить ветку `feat/core-bridge` (решает владелец).

---

## Самопроверка плана по спеке

| Требование спеки | Где реализовано |
| :- | :- |
| Мост: быстрый выход, один общий срок 0,3 с, нет сокета — тихо, зависший получатель не держит | Task 5 (`testNoServer…`, `testHungReceiverDoesNotBlockBridgePastDeadline`), Task 9 шаг 8 |
| Полный ввод только с запросом, остальным облегчённый | Task 1 (`slimmed`), Task 5 (`testPlainEventsCarrySlimToolInput…`) |
| Решение `allow`/`deny` закрывает диалог; хук не прерывается при ответе в терминале; карточку снимает ядро по событию | Task 5, Task 7, Task 9 b–c |
| Канал держится, `autoOpenPolicy` управляет только раскрытием | Task 7 (`testAutoOpenPolicyFalseKeepsChannel…`) |
| Мёртвый канал, дубль идентификатора, `releaseAllCards`, «не доставлено» | Task 7 |
| Вопросы без кнопок; сессии без терминала игнорируются целиком | Task 2 (`PermissionPolicy`, `cardable`), Task 7, Task 9 i |
| Номер процесса: `CLAUDE_PID` → предок `claude`/`claude.exe` → 0 | Task 4, Task 5 (`testUnknownSessionProcessGivesPidZero…`) |
| Сокет: права каталога 0700 при каждом запуске, права файла 0600, проверка владельца пира, не перехватывать живого слушателя, не удалять чужой файл | Task 5 |
| Установка/удаление хуков, метка, точная разница, предупреждение о переформатировании, отказ при неожиданном виде, статус моста, симлинк и права | Task 6, Task 8 (`topbar-dev`), Task 9 шаги 2 и 9 |
| Автомат: переходы, очередь, привязка по `tool_use_id`, список вызовов, тишина, Esc-правило для Bash, upsert, дедупликация по процессу, запоздавший `SessionEnd` | Task 2 |
| Подпись «проект · ветка», суффикс `#2`, worktree/detached HEAD | Task 2 (`displayTitles`), Task 3 |
| Сводка и приоритет статусов | Task 2 (`Summary`, `urgency`) |
| Проверка живости раз в 10 с по паре pid+время старта | Task 4, Task 7 |
| Известные ограничения (Esc, отказ/разрешение в терминале на долгой команде) подтверждаются измерением | Task 9 e–h |
| Открытые вопросы 2–9 | Task 9 шаги 5–7 |
| Окно острова, карточка, меню, звук, переход к сессии, «владелец смотрит», запуск при входе, сон/монитор (через `releaseAllCards`), обрезка длинного ввода в интерфейсе, режим разрешений значком | **Часть 2** (отдельный план после задачи 9) |

Пробелов внутри части 1 нет. Типы и имена сверены между задачами (`BridgeMessage`, `CoreReply`, `RunningTool`, `PermissionRequest.detail/toolUseId/cardable`, `SessionStore.apply/resolve/markViewed/sweepQuiet/remove`, `SessionHub.decide/releaseAllCards/markViewed/snapshot/tickNow/flush`, `HookInstaller.install/remove/isInstalled/bridgePaths/diff/willReformat`). Весь код в плане скомпилирован и прогнан (87 тестов, 0 сбоев, три прогона подряд) на Xcode 27.2 / Swift 6.4.2 перед записью.

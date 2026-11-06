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
    /// Приложение-хост по идентификатору (его выводим вперёд); у незнакомых терминалов `hostApp` пуст, а это поле есть.
    public var hostBundleId: String? = nil
    public var tty: String?
    public var hints: [String: String]
    public var permissionMode: String?
    public var firstSeenAt: Date
    public var lastEventAt: Date
    public var running: [RunningTool]
    public var unseenDone: Bool
    public var queue: [PermissionRequest]

    public var toolRunning: Bool { !running.isEmpty }

    /// Совпадает ли то, что видит интерфейс (время событий, список вызовов, признаки окна и pid не в счёт).
    public func sameForDisplay(as other: Session) -> Bool {
        sessionId == other.sessionId && project == other.project && projectRoot == other.projectRoot
            && branch == other.branch && status == other.status && currentAction == other.currentAction
            && hostApp == other.hostApp && hostBundleId == other.hostBundleId && tty == other.tty && permissionMode == other.permissionMode
            && unseenDone == other.unseenDone
            && queue.map(\.requestId) == other.queue.map(\.requestId)
    }

    public static func sameForDisplay(_ a: [Session], _ b: [Session]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.sameForDisplay(as: $1) }
    }
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

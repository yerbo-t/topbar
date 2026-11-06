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
    /// false — вопросы и планы (`ExitPlanMode`, а также `AskUserQuestion`, которого остров не умеет показать): сессия «ждёт»,
    /// но карточки нет, ответ — в терминале.
    public let cardable: Bool
    /// Вопрос карточки целиком: «Разрешить выполнить команду?».
    public var question: String = ""
    /// Пояснение к запросу: что Claude написал о команде (`description` у Bash), путь файла, запрос поиска.
    public var purpose: String? = nil
    /// Вопросы Claude с вариантами (`AskUserQuestion`), если остров их умеет показать: на них отвечают кнопками на карточке.
    public var questions: [AskQuestion]? = nil
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
    /// Журнал сессии, из которого читается её имя.
    public var transcriptPath: String? = nil
    /// Имя сессии: заданное владельцем (`/rename`) или придуманное Claude Code; nil — пока нет.
    public var name: String? = nil

    public var toolRunning: Bool { !running.isEmpty }

    /// Совпадает ли то, что видит интерфейс (время событий, список вызовов, признаки окна и pid не в счёт).
    public func sameForDisplay(as other: Session) -> Bool {
        sessionId == other.sessionId && project == other.project && projectRoot == other.projectRoot
            && branch == other.branch && status == other.status && currentAction == other.currentAction
            && hostApp == other.hostApp && hostBundleId == other.hostBundleId && tty == other.tty && permissionMode == other.permissionMode
            && unseenDone == other.unseenDone && name == other.name
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

/// Какие инструменты остров не превращает в карточку «разрешить/отклонить»: для них эти кнопки бессмысленны.
/// У `AskUserQuestion` своя карточка с вариантами ответа (когда вопрос остров умеет показать, см. `AskQuestions`).
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
        case "AskUserQuestion":
            return "Задаёт вопрос"
        case "ExitPlanMode":
            return "Ждёт решения по плану"
        default:
            return toolName
        }
    }

    /// Полный текст для карточки (ограничен 4000 символами; обрезка помечается).
    public static func detail(toolName: String?, input: JSONValue?, limit: Int = 4000) -> String {
        var text: String
        if toolName == "Bash", let command = input?["command"]?.stringValue {
            text = command
        } else if let change = editDiff(toolName: toolName, input: input) {
            text = change
        } else if toolName == "Write", let content = input?["content"]?.stringValue {
            text = content.isEmpty ? "(пустой файл)" : content
        } else if let input, let data = try? Self.encoder.encode(input) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        if text.count > limit { text = String(text.prefix(limit)) + "\n… показано не всё" }
        return text
    }

    /// Правка файла как разница: строки «- было», «+ станет» (путь — в пояснении под вопросом). nil — не правка.
    static func editDiff(toolName: String?, input: JSONValue?) -> String? {
        func one(_ edit: JSONValue?) -> String? {
            guard let old = edit?["old_string"]?.stringValue, let new = edit?["new_string"]?.stringValue else { return nil }
            func mark(_ text: String, _ sign: String) -> String {
                text.split(separator: "\n", omittingEmptySubsequences: false).map { sign + " " + $0 }.joined(separator: "\n")
            }
            var parts = [old.isEmpty ? nil : mark(old, "-"), new.isEmpty ? nil : mark(new, "+")].compactMap { $0 }
            if case .bool(true)? = edit?["replace_all"] { parts.append("(во всех местах файла)") }
            return parts.joined(separator: "\n")
        }
        switch toolName {
        case "Edit": return one(input)
        case "MultiEdit":
            guard case .array(let edits)? = input?["edits"] else { return nil }
            let all = edits.compactMap { one($0) }
            return all.isEmpty ? nil : all.joined(separator: "\n\n")
        default: return nil
        }
    }

    /// Вопрос карточки: что именно владелец разрешает, словами, а не именем инструмента.
    public static func question(toolName: String?, input: JSONValue?) -> String {
        let name = toolName ?? ""
        let file = fileName(input)
        switch name {
        case "Bash": return "Разрешить выполнить команду?"
        case "Edit", "MultiEdit": return file.map { "Разрешить изменить файл \($0)?" } ?? "Разрешить изменить файл?"
        case "Write": return file.map { "Разрешить записать файл \($0)?" } ?? "Разрешить записать файл?"
        case "Read": return file.map { "Разрешить прочитать файл \($0)?" } ?? "Разрешить прочитать файл?"
        case "NotebookEdit": return file.map { "Разрешить изменить блокнот \($0)?" } ?? "Разрешить изменить блокнот?"
        case "WebFetch":
            let host = input?["url"]?.stringValue.flatMap { URL(string: $0)?.host }
            return host.map { "Разрешить открыть страницу \($0)?" } ?? "Разрешить открыть страницу?"
        case "WebSearch": return "Разрешить поиск в интернете?"
        case "Glob", "Grep": return "Разрешить поиск по файлам?"
        case "Task", "Agent": return "Разрешить запустить субагента?"
        case "Skill":
            return input?["skill"]?.stringValue.map { "Разрешить запустить навык \($0)?" } ?? "Разрешить запустить навык?"
        case "KillShell", "KillBash": return "Разрешить остановить фоновую команду?"
        default:
            // mcp__<сервер>__<инструмент>
            let parts = name.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                return "Разрешить \(parts[2...].joined(separator: "__")) из \(parts[1])?"
            }
            return name.isEmpty ? "Разрешить?" : "Разрешить инструмент \(name)?"
        }
    }

    /// Пояснение под вопросом карточки (nil — пояснять нечего, всё видно в самом запросе).
    public static func purpose(toolName: String?, input: JSONValue?) -> String? {
        let text: String?
        switch toolName {
        case "Bash", "Task", "Agent": text = input?["description"]?.stringValue
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            text = (input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue).map(abbreviateHome)
        case "WebSearch": text = input?["query"]?.stringValue
        default: text = nil
        }
        guard let line = text.map({ oneLine($0, limit: 200) })?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return line
    }

    private static func fileName(_ input: JSONValue?) -> String? {
        let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue ?? ""
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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

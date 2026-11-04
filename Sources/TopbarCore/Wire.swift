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

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
    /// Журнал сессии (`~/.claude/projects/…/<session>.jsonl`): из него берётся только имя сессии.
    public var transcriptPath: String?

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
        case transcriptPath = "transcript_path"
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
        agentType: String? = nil,
        transcriptPath: String? = nil
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
        self.transcriptPath = transcriptPath
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

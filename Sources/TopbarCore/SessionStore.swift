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
        if let host = Self.hostName(msg.termProgram, bundleId: msg.hostBundleId) { s.hostApp = host }
        if let tty = msg.tty { s.tty = tty }
        if !msg.hints.isEmpty, s.hints != msg.hints { s.hints = msg.hints }
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

    /// Приложение-хост по `TERM_PROGRAM`, а если его нет (расширение Claude Code в VS Code) — по идентификатору приложения.
    public static func hostName(_ termProgram: String?, bundleId: String? = nil) -> String? {
        switch termProgram {
        case "ghostty": return "Ghostty"
        case "vscode": return "VS Code"
        case let other?: return other
        case nil: break
        }
        switch bundleId {
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders": return "VS Code"
        case "com.mitchellh.ghostty": return "Ghostty"
        default: return nil
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

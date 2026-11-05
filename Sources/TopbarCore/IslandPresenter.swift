import Foundation

public enum IslandMode: Equatable, Hashable {
    case hidden
    case collapsed
    case list
    case card(requestId: String)
}

/// Что показывает остров. Чистая логика без окон: по списку сессий и событиям карточек
/// решает, скрыт ли остров, свёрнут, раскрыт списком или показывает карточку запроса.
public struct IslandPresenter {
    public private(set) var sessions: [Session] = []
    /// Очередь карточек в порядке прихода (первая показывается).
    public private(set) var cardQueue: [String] = []
    public private(set) var listOpen = false

    public init() {}

    public var mode: IslandMode {
        if let id = currentCardId { return .card(requestId: id) }
        if sessions.isEmpty { return .hidden }
        return listOpen ? .list : .collapsed
    }

    /// Первая карточка, запрос которой ещё существует.
    public var currentCardId: String? {
        cardQueue.first { id in sessions.contains { $0.queue.contains { $0.requestId == id && $0.cardable } } }
    }

    public var currentCard: (request: PermissionRequest, session: Session)? {
        guard let id = currentCardId else { return nil }
        for s in sessions { if let r = s.queue.first(where: { $0.requestId == id }) { return (r, s) } }
        return nil
    }

    /// Сколько ещё карточек стоит в очереди после текущей.
    public var queuedBehindCurrent: Int {
        max(0, cardQueue.filter { id in sessions.contains { $0.queue.contains { $0.requestId == id && $0.cardable } } }.count - 1)
    }

    public mutating func update(sessions: [Session]) {
        self.sessions = sessions
        let live = Set(sessions.flatMap { $0.queue.map(\.requestId) })
        cardQueue.removeAll { !live.contains($0) }
        if sessions.isEmpty { listOpen = false }
    }

    /// Появился запрос, который нужно показать сразу.
    public mutating func requestOpened(_ id: String) {
        if !cardQueue.contains(id) { cardQueue.append(id) }
    }

    public mutating func requestClosed(_ id: String) { cardQueue.removeAll { $0 == id } }

    /// Владелец убрал карточку, не отвечая (диалог остаётся в терминале).
    public mutating func dismissCard() { if let id = currentCardId { cardQueue.removeAll { $0 == id } } }

    /// Клик по строке «ждёт»: открыть карточки запросов этой сессии первыми.
    public mutating func openCards(forSession sessionId: String) {
        guard let s = sessions.first(where: { $0.sessionId == sessionId }) else { return }
        let ids = s.queue.filter(\.cardable).map(\.requestId)
        cardQueue = ids + cardQueue.filter { !ids.contains($0) }
    }

    public mutating func toggleList() { listOpen.toggle() }
    public mutating func setList(open: Bool) { listOpen = open && !sessions.isEmpty }
    public mutating func collapse() { listOpen = false }

    // MARK: сводка

    /// Пункты сводки: «1 ждёт · 1 готово · 2 работает»; нули опускаются. Простаивающие показываются, только если больше
    /// нечего показать («2 простаивает»), иначе остров был бы пустой чёрной плашкой.
    public var summaryChips: [SummaryChip] {
        var counts: [SessionStatus: Int] = [:]
        for s in sessions { counts[s.status, default: 0] += 1 }
        func chip(_ status: SessionStatus, _ word: (Int) -> String) -> SummaryChip? {
            counts[status].map { SummaryChip(status: status, count: $0, text: word($0)) }
        }
        let active = [
            chip(.waitingPermission) { "\($0) ждёт" },
            chip(.done) { "\($0) готово" },
            chip(.working) { "\($0) работает" },
        ].compactMap { $0 }
        if active.isEmpty, let idle = chip(.idle, { "\($0) простаивает" }) { return [idle] }
        return active
    }

    public var summaryParts: [(status: SessionStatus, text: String)] { summaryChips.map { ($0.status, $0.text) } }

    public var summaryText: String { summaryParts.map(\.text).joined(separator: " · ") }

    /// Самый срочный статус (цвет острова).
    public var topStatus: SessionStatus? { sessions.map(\.status).min { $0.urgency < $1.urgency } }
}

/// «Владелец смотрит на сессию»: первая версия — активное приложение совпадает с хостом сессии.
public enum WatchPolicy {
    static let bundleIds: [String: String] = [
        "Ghostty": "com.mitchellh.ghostty",
        "VS Code": "com.microsoft.VSCode",
    ]

    /// Владелец смотрит на сессию: активно приложение-хост; для Ghostty, если известен терминал сессии и удалось узнать
    /// терминал в фокусе (`ghosttyFocusedTTY`, например `/dev/ttys004`), они должны совпасть. Не удалось узнать — по приложению.
    public static func isWatching(_ session: Session, frontmostBundleId: String?, ghosttyFocusedTTY: String? = nil) -> Bool {
        guard let host = session.hostApp, let expected = bundleIds[host], let front = frontmostBundleId, front == expected else {
            return false
        }
        if host == "Ghostty", let tty = session.tty, let focused = ghosttyFocusedTTY {
            return focused == "/dev/" + tty
        }
        return true
    }

    public static func bundleId(forHost host: String?) -> String? { host.flatMap { bundleIds[$0] } }
}

/// Чтение и запись settings.json Claude Code: симлинк и права файла сохраняются.
public enum SettingsFile {
    public static func resolved(_ path: String) -> URL { URL(fileURLWithPath: path).resolvingSymlinksInPath() }

    public static func read(_ path: String) -> Data? { FileManager.default.contents(atPath: resolved(path).path) }

    public static func write(_ data: Data, to path: String) throws {
        let url = resolved(path)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }
}

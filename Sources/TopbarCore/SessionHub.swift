import Foundation
import os

/// Склеивает сокет, автомат статусов и проверку живости.
/// Внутренняя работа идёт на `queue`; все колбэки уходят на отдельную очередь `callbackQueue`
/// (интерфейс подставит главную), поэтому из колбэка безопасно вызывать `snapshot()`, `decide()` и т. д.
public final class SessionHub {
    private static let log = Logger(subsystem: "dev.topbar.app", category: "hub")
    public let queue = DispatchQueue(label: "topbar.hub")
    public let callbackQueue: DispatchQueue

    /// Раскрывать ли остров сам по этому запросу; ответ можно дать позже и с любой очереди (ожидание не блокирует хаб).
    /// false (владелец смотрит на сессию, нет экрана) — запрос всё равно остаётся в сессии, и карточку можно открыть
    /// вручную: канал к мосту держится.
    public var autoOpenDecider: (Session, PermissionRequest, @escaping (Bool) -> Void) -> Void = { _, _, done in done(true) }
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
    private var lastEmitted: [Session] = []
    private let livenessInterval: TimeInterval
    private let hasChildProcess: (Session) -> Bool
    private let staleToolAfter: TimeInterval

    public init(
        socketPath: String,
        livenessInterval: TimeInterval = 10,
        staleToolAfter: TimeInterval = 20,
        callbackQueue: DispatchQueue = DispatchQueue(label: "topbar.hub.callbacks"),
        branchProvider: @escaping (String) -> String? = BranchReader.branch(at:),
        nameProvider: @escaping (String) -> String? = SessionNameReader().name(at:),
        hasChildProcess: @escaping (Session) -> Bool = { $0.pid <= 0 || !ProcessProbe.childPids(of: $0.pid).isEmpty }
    ) {
        self.store = SessionStore(branchProvider: branchProvider, nameProvider: nameProvider)
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
        t.schedule(deadline: .now() + livenessInterval, repeating: livenessInterval, leeway: .seconds(2)) // реже будить процессор
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

    /// Ответ владельца на вопрос Claude с карточки (вопрос → выбранные подписи вариантов). Выбор проверяется по самим вопросам
    /// запроса; не подошёл — `completion(false)`, карточка остаётся. Остальное — как у `decide`.
    public func answer(requestId: String, picks: [String: [String]], completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            func reject(_ reason: String) {
                Self.log.notice("ответ на вопрос не принят: \(reason, privacy: .public)")
                emit { completion?(false) }
            }
            guard channels[requestId] != nil else { return reject("мост уже отключился или запрос закрыт") }
            guard let request = store.sessions.values.lazy.compactMap({ $0.queue.first { $0.requestId == requestId } }).first,
                  let questions = request.questions else { return reject("запрос не найден или это не вопрос с вариантами") }
            guard let answers = AskQuestions.answers(from: picks, for: questions) else { return reject("выбор не подходит к вопросам") }
            guard let channel = channels.removeValue(forKey: requestId) else { return reject("канал пропал") }
            let delivered = channel.send(.answered(answers))
            if delivered {
                store.resolve(requestId: requestId)
                notifyChange()
            } else {
                Self.log.notice("ответ на вопрос не дошёл до моста: сокет закрыт")
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

    /// Убрать сессию с острова, не трогая её процесс: открытые запросы Claude задаст в терминале. Живая сессия вернётся со
    /// своим следующим событием.
    public func forget(sessionId: String) {
        queue.async { [self] in
            remove(sessionId: sessionId)
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

        var toOpen: (PermissionRequest, Session)?
        if isRequest {
            if let session = store.sessions[ev.sessionId],
               let request = session.queue.first(where: { $0.requestId == msg.requestId }),
               request.cardable {
                channels[request.requestId] = channel
                channel.onClose = { [weak self] in self?.channelClosed(request.requestId) }
                toOpen = (request, session)
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
        notifyChange()
        if let (request, session) = toOpen {
            autoOpenDecider(session, request) { [weak self] open in
                guard open, let self else { return }
                self.queue.async {
                    // Запрос мог закрыться, пока решали (ответили в терминале).
                    guard self.channels[request.requestId] != nil else { return }
                    self.emit { self.onRequestOpened?(request, session) }
                }
            }
        }
    }

    /// Мост отключился (хук истёк, процесс убит): кнопки на карточке уже бесполезны.
    private func channelClosed(_ requestId: String) {
        guard channels.removeValue(forKey: requestId) != nil else { return }
        emit { self.onRequestClosed?(requestId) }
    }

    /// Убрать сессию; её открытые запросы возвращаются в терминал («без решения»).
    private func remove(sessionId: String) {
        for effect in store.remove(sessionId: sessionId) {
            if case .requestClosed(let id) = effect {
                channels.removeValue(forKey: id)?.send(.none)
                emit { self.onRequestClosed?(id) }
            }
        }
    }

    private func tick() {
        var changed = false
        for s in store.sessions.values where s.pid > 0 && !ProcessProbe.isAlive(pid: s.pid, startedAt: s.processStartedAt) {
            remove(sessionId: s.sessionId)
            changed = true
        }
        if !store.sweepQuiet(now: Date(), staleToolAfter: staleToolAfter, hasChildProcess: hasChildProcess).isEmpty { changed = true }
        if changed { notifyChange() }
    }

    /// Сообщает интерфейсу только о том, что он видит: события, не меняющие картинку (например, `PostToolUse`),
    /// перерисовку не вызывают.
    private func notifyChange() {
        let sessions = store.snapshot()
        if Session.sameForDisplay(sessions, lastEmitted) { return }
        lastEmitted = sessions
        emit { self.onChange?(sessions) }
    }
}

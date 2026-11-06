import AppKit
import Combine
import SwiftUI
import TopbarCore

/// Где и какого размера чёрная фигура острова внутри окна (окно на время перехода больше фигуры).
struct ShapeRect: Equatable {
    var x: CGFloat
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
}

/// Связывает хаб сессий с видом: хранит состояние острова и принимает действия владельца.
@MainActor
final class IslandViewModel: ObservableObject {
    private(set) var presenter = IslandPresenter()
    /// Подписи сессий: крупно имя сессии (или проект), мелко проект и ветка.
    @Published private(set) var labels: [String: SessionLabel] = [:]
    /// Что играет в системе (nil — ничего) и обложка; положение в треке считает вид сам.
    @Published private(set) var nowPlaying: NowPlaying?
    private var sourceCache: (pid: Int, app: NSRunningApplication?)?
    @Published private(set) var artwork: NSImage?
    private var pausedSince: Date?
    private var pauseTimer: DispatchWorkItem?
    let player = NowPlayingService()
    /// Фигура острова: меняется пружиной, пока окно больше неё (см. `IslandPanelController.layout`).
    @Published var shape = ShapeRect(x: 0, width: 0, height: 0, radius: 11)
    /// Размеры считаются один раз на изменение (замер текста не должен повторяться при каждой перерисовке).
    private(set) var size: CGSize = .zero
    /// Раскладка «ушей» свёрнутого острова: подстраивается под свободное место до меню приложения слева и до значков справа.
    private(set) var ears = EarLayout(style: .full, left: [], right: [], leftWidth: 110, rightWidth: 110)
    /// Свободное место по сторонам выреза: слева — до последнего меню приложения, справа — до первого значка
    /// (nil — места вдоволь или не удалось узнать).
    private var space = Space(left: nil, right: nil)
    private var availableRight: CGFloat? { space.right }
    private var spaceCheckedAt = Date.distantPast
    /// Переход между столами и экранами: пока идёт, значки в строке меню перекладываются и замеру места верить нельзя.
    private var spaceFrozenUntil = Date.distantPast
    /// Новое значение свободного места принимается, когда два замера подряд его подтвердили (мигание на переходах отсекается).
    private var pendingFree: (value: Space, seen: Int)?
    private var hasMeasuredSpace = false
    private var pendingSessions: [Session]?
    private var flushTask: Task<Void, Never>?
    /// Список раскрыт кликом (остаётся, пока владелец не свернёт); наведением раскрывается временно.
    private var pinned = false
    private var hoverTask: Task<Void, Never>?

    /// Ответ на вопрос Claude, который набирается на карточке: какой вопрос по счёту и что уже выбрано.
    struct AskDraft: Equatable {
        var requestId: String?
        var index = 0
        var picks: [String: [String]] = [:]
        var questionCount = 0
    }
    private(set) var ask = AskDraft()

    /// Значки строки меню: из них собирается ряд закреплённых над списком сессий (nil — не подключено).
    var icons: MenuBarListModel? {
        didSet {
            iconsObserver = icons?.objectWillChange.sink { [weak self] _ in
                // Изменение приходит до того, как значения обновились: пересчёт — на следующем обороте.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.iconsChanged() } }
            }
            icons?.onPressed = { [weak self] in self?.collapse() }
        }
    }
    private var iconsObserver: AnyCancellable?
    private var lastPinnedRowCount = 0

    let hub: SessionHub
    let system: SystemState
    var geometry: NotchGeometry?
    /// Вызывается после каждого изменения, которое может поменять размер окна.
    var onLayoutChange: (() -> Void)?

    init(hub: SessionHub, system: SystemState) {
        self.hub = hub
        self.system = system
        self.geometry = NotchGeometry.find()

        hub.onChange = { [weak self] sessions in
            MainActor.assumeIsolated { self?.enqueue(sessions) }
        }
        hub.onRequestOpened = { [weak self] request, _ in
            MainActor.assumeIsolated {
                self?.flushPending()   // карточке нужны свежие сессии
                self?.apply { $0.requestOpened(request.requestId) }
            }
        }
        hub.onRequestClosed = { [weak self] id in
            MainActor.assumeIsolated { self?.apply { $0.requestClosed(id) } }
        }
        hub.onSessionDone = { [weak self] session in
            MainActor.assumeIsolated { self?.sessionDone(session) }
        }
        // Решение «раскрывать ли остров сам» принимаем на главном потоке (AppleScript не любит других) и не блокируем хаб.
        hub.autoOpenDecider = { [weak self] session, _, done in
            Task { @MainActor in
                guard let self, !CommandLine.arguments.contains("--debug-no-autoopen") else { return done(false) }
                done(self.system.hasNotchScreen && !self.isWatching(session))
            }
        }
        player.onMessage = { [weak self] message in self?.handle(message) }
        player.onUnavailable = { [weak self] in self?.playerUnavailable() }
        recomputeLayout()
    }

    // MARK: плеер

    func startPlayerIfEnabled() {
        // Отладка: показать плеер без настоящей музыки (`--debug-fake-player`) — трек играет от «приложения» topbar.
        if CommandLine.arguments.contains("--debug-fake-player") {
            nowPlaying = NowPlaying(title: "Ночной маршрут", artist: "Demo Tape", album: nil, playing: true, duration: 214, elapsed: 83,
                                    rate: 1, timestamp: Date(), pid: Int(ProcessInfo.processInfo.processIdentifier))
            updateMediaActive()
            return
        }
        if Settings.playerEnabled { player.start() }
    }

    func setPlayerEnabled(_ on: Bool) {
        Settings.playerEnabled = on
        if on {
            player.start()
        } else {
            player.stop()
            nowPlaying = nil
            artwork = nil
            updateMediaActive()
        }
    }

    private func playerUnavailable() {
        nowPlaying = nil
        artwork = nil
        updateMediaActive()
    }

    private func handle(_ message: NowPlayingMessage) {
        switch message {
        case .state(let state, let art):
            applyArtwork(art.ignoringTransientClear(previous: nowPlaying, current: state))
            let justPaused = (nowPlaying?.playing ?? false) && !state.playing
            nowPlaying = state
            if state.playing { pausedSince = nil } else if justPaused || pausedSince == nil { pausedSince = Date() }
        case .nothing(let art):
            applyArtwork(art)
            nowPlaying = nil
            pausedSince = nil
        case .failure:
            nowPlaying = nil
        }
        updateMediaActive()
    }

    private func applyArtwork(_ update: ArtworkUpdate) {
        switch update {
        case .unchanged: break
        case .cleared: artwork = nil
        case .data(let data): artwork = NSImage(data: data)
        }
    }

    /// Показывать ли плеер: играет или недавно поставлен на паузу. Когда пауза затянется, остров уберёт плеер сам.
    private func updateMediaActive() {
        let visible = Settings.playerEnabled && MediaVisibility.isVisible(nowPlaying, pausedSince: pausedSince, now: Date())
        apply { $0.setMedia(active: visible) }
        pauseTimer?.cancel()
        if visible, let nowPlaying, !nowPlaying.playing, let pausedSince {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updateMediaActive() } }
            pauseTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, MediaVisibility.pauseGrace - Date().timeIntervalSince(pausedSince) + 0.5), execute: work)
        }
    }

    /// Пауза или «играть» — явной командой по тому, что показано, а не «переключить»: так не перепутаем, если состояние устарело.
    func mediaToggle() {
        let willPlay = !(nowPlaying?.playing ?? false)
        player.send(willPlay ? .play : .pause)
        optimisticPlaying(willPlay)
    }
    func mediaNext() { player.send(.next) }
    func mediaPrevious() { player.send(.previous) }

    func mediaSeek(to seconds: Double) {
        player.send(.seek(seconds))
        if var state = nowPlaying {
            state.elapsed = seconds
            state.timestamp = Date()
            nowPlaying = state
        }
    }

    /// Кнопка реагирует сразу, не дожидаясь ответа системы (он придёт через ~0,1 с и поправит, если что).
    private func optimisticPlaying(_ playing: Bool) {
        guard var state = nowPlaying else { return }
        state.elapsed = state.position(at: Date())
        state.timestamp = Date()
        state.playing = playing
        nowPlaying = state
    }

    /// Приложение, откуда играет музыка (Dia, Spotify…): по pid; если pid у служебного процесса (браузер, помощник), то
    /// приложение с окном среди его предков. nil — не нашли.
    var mediaSourceApp: NSRunningApplication? {
        guard let pid = nowPlaying?.pid, pid > 0 else { return nil }
        // Вид спрашивает это на каждом обновлении (раз в секунду, пока идёт трек): обход процессов запоминаем по pid.
        if let cached = sourceCache, cached.pid == pid, cached.app?.isTerminated != true { return cached.app }
        var found: NSRunningApplication?
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.activationPolicy != .prohibited, app.bundleIdentifier != nil {
            found = app
        } else if let id = SessionJumper.windowedAppBundleId(ancestorOf: Int32(pid)) {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        }
        sourceCache = (pid, found)
        return found
    }

    var mediaSourceName: String? { mediaSourceApp?.localizedName }

    /// Вывести вперёд приложение-источник музыки и свернуть остров.
    func openMediaSource() {
        guard let app = mediaSourceApp else { return }
        app.unhide()
        app.activate()
        collapse()
    }

    /// Владелец смотрит на сессию: приложение-хост активно, а для терминалов с точным определением (Ghostty, Terminal, iTerm2) —
    /// ещё и вкладка сессии в фокусе.
    func isWatching(_ session: Session) -> Bool {
        let front = system.frontmostBundleId
        var focused: String?
        if let front, WatchPolicy.hostBundleId(of: session) == front, TerminalScripting.supports(front) {
            // Первый раз, когда владелец в терминале с сессией, спросим «Автоматизацию»: тогда узнаем и вкладку.
            if !AutomationAccess.shared.isGranted(front) { AutomationAccess.shared.refresh(front, ask: true) }
            if session.tty != nil { focused = TerminalScripting.focusedTTY(bundleId: front) }
        }
        return WatchPolicy.isWatching(session, frontmostBundleId: front, focusedTTY: focused)
    }

    var mode: IslandMode { presenter.mode }

    /// Подпись сессии для вида; пока подписи не посчитаны — проект и ветка.
    func label(for session: Session) -> SessionLabel {
        labels[session.sessionId] ?? SessionLabel(title: session.name ?? session.project, project: session.name == nil ? nil : session.project, branch: session.branch)
    }


    // MARK: размеры

    static let listWidth: CGFloat = 440

    /// Пересчитать размеры; зовётся после каждого изменения состояния и смены экрана.
    func recomputeLayout() {
        ears = computeEars()
        size = computeSize()
    }

    private func computeEars() -> EarLayout {
        // Только плеер, без сессий: слева обложка, справа «эквалайзер».
        if presenter.mediaActive, presenter.summaryChips.isEmpty {
            let width: CGFloat = 42
            // Меню приложения вплотную к вырезу: обложка уходит направо, «эквалайзер» убирается.
            if let left = space.left, left < width {
                return EarLayout(style: .compact, left: [], right: [], leftWidth: 0, rightWidth: min(width, availableRight ?? width), showsMedia: true)
            }
            return EarLayout(style: .compact, left: [], right: [], leftWidth: width, rightWidth: min(width, availableRight ?? width))
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return EarLayout.make(chips: presenter.summaryChips, availableLeft: space.left, availableRight: availableRight, withMedia: presenter.mediaActive) {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    /// Перешли на другой стол или поменялись параметры экрана: ближайшие две секунды замеры места не принимаем.
    func noteScreenTransition() {
        spaceFrozenUntil = Date().addingTimeInterval(2)
        pendingFree = nil
    }

    /// Узнать, сколько места до первого значка справа от выреза. true — место изменилось и остров надо пересобрать.
    /// Значки меняются сами по себе (SwiftBar меняет заголовок, приложения добавляют и убирают значки), поэтому
    /// пока остров свёрнут, это проверяется раз в пару секунд. Чтобы «уши» не дёргались при переходе между столами, новое
    /// значение принимается только после двух одинаковых замеров подряд и не во время перехода; самый первый замер — сразу.
    @discardableResult
    func refreshMenuBarSpace(force: Bool = false, immediate: Bool = false) -> Bool {
        guard let geometry else { return false }
        if !force, Date().timeIntervalSince(spaceCheckedAt) < 0.5 { return false }
        if Date() < spaceFrozenUntil { return false }
        spaceCheckedAt = Date()
        var right = MenuBarLayout.freeSpaceRightOfNotch(on: geometry.screen, notchWidth: geometry.notchWidth)
        var left = MenuBarLayout.freeSpaceLeftOfNotch(on: geometry.screen, notchWidth: geometry.notchWidth)
        // Отладка: подставить свободное место (`--debug-free-right 36`, `--debug-free-left 0`), чтобы проверить виды ушей.
        if let value = Self.debugValue("--debug-free-right") { right = .points(value) }
        if let value = Self.debugValue("--debug-free-left") { left = .points(value) }
        // Сторона, которую не разглядеть (строка спрятана, нет «Универсального доступа»), остаётся при последнем известном месте.
        func value(_ sample: MenuBarLayout.FreeSpace, _ last: CGFloat?) -> CGFloat? {
            switch sample {
            case .unknown: return last
            case .unlimited: return nil
            case .points(let v): return v
            }
        }
        if case .unknown = right, case .unknown = left { return false }
        let free = Space(left: value(left, space.left), right: value(right, space.right))
        if free.same(as: space) {
            pendingFree = nil
            hasMeasuredSpace = true
            return false
        }
        if hasMeasuredSpace, !immediate {
            if let pending = pendingFree, pending.value.same(as: free) { pendingFree = (free, pending.seen + 1) } else { pendingFree = (free, 1) }
            guard (pendingFree?.seen ?? 0) >= 2 else { return false }
        }
        hasMeasuredSpace = true
        pendingFree = nil
        space = free
        recomputeLayout()
        return true
    }

    private static func debugValue(_ flag: String) -> CGFloat? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count,
              let value = Double(CommandLine.arguments[i + 1]) else { return nil }
        return CGFloat(value)
    }

    /// Сдвиг центра окна от середины экрана: свёрнутый остров может быть несимметричным (справа места мало).
    var centerShift: CGFloat {
        presenter.mode == .collapsed ? (ears.rightWidth - ears.leftWidth) / 2 : 0
    }

    /// Радиус нижних углов: у свёрнутого острова — как у выреза, у раскрытого — мягче.
    var cornerRadius: CGFloat { presenter.mode == .collapsed ? 11 : 28 }

    private func computeSize() -> CGSize {
        let notchH = geometry?.notchHeight ?? 32
        let notchW = geometry?.notchWidth ?? 200
        switch presenter.mode {
        case .hidden:
            return .zero
        case .collapsed:
            return CGSize(width: notchW + ears.leftWidth + ears.rightWidth, height: notchH)
        case .list:
            let rows = CGFloat(presenter.sessions.count)
            let player = presenter.mediaActive ? PlayerView.height : 0
            let pinned = pinnedRowCount > 0 ? PinnedRowView.height : 0
            return CGSize(width: Self.listWidth, height: notchH + 10 + player + pinned + rows * 54 + 44)
        case .card:
            guard let card = presenter.currentCard else { return .zero }
            let m = CardMetrics.self
            let label = label(for: card.session)
            let hasContext = !label.context.isEmpty || card.session.hostApp != nil
            let header = m.titleLine + (hasContext ? m.contextLine : 0)
            if let questions = card.request.questions {
                let index = min(ask.index, questions.count - 1)
                let body = QuestionMetrics.bodyHeight(questions[index], index: index, count: questions.count)
                return CGSize(width: m.width, height: ceil(notchH + m.top + header + m.afterHeader + body + m.beforeActions + m.actions + m.bottom))
            }
            let question = CGFloat(m.lines(card.request.question, font: m.questionFont, limit: 2)) * m.questionLine
            let purpose = card.request.purpose.map { m.purposeGap + CGFloat(m.lines($0, font: m.purposeFont, limit: 2)) * m.purposeLine } ?? 0
            // Строки команды с переносами: сколько знаков моноширинного шрифта входит в ящик.
            let perLine = max(20, Int((m.inner - 2 * m.codePad) / ceil(("x" as NSString).size(withAttributes: [.font: m.codeFont]).width)))
            let estimated = card.request.detail.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(perLine)))) }
            let lines = CGFloat(min(max(estimated, 1), 10))
            let code = lines * m.codeLine + 2 * m.codePad + 2
            let height = notchH + m.top + header + m.afterHeader + question + purpose + m.beforeCode + code + m.beforeActions + m.actions + m.bottom
            return CGSize(width: m.width, height: ceil(height))
        }
    }

    // MARK: действия

    func toggleList() {
        pinned.toggle()
        apply { $0.setList(open: pinned) }
    }

    func collapse() {
        pinned = false
        apply { $0.collapse() }
    }

    func hover(_ inside: Bool) {
        hoverTask?.cancel()
        guard !pinned else { return }
        if inside {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.apply { $0.setList(open: true) }
            }
        } else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                self?.apply { $0.setList(open: false) }
            }
        }
    }

    func rowTapped(_ session: Session) {
        if session.status == .waitingPermission, session.queue.contains(where: \.cardable) {
            apply { $0.openCards(forSession: session.sessionId) }
            return
        }
        SessionJumper.open(session)
        hub.markViewed(sessionId: session.sessionId)
    }

    func jump(to session: Session) {
        SessionJumper.open(session)
        apply { $0.dismissCard() }
    }

    func decide(allow: Bool) {
        guard let card = presenter.currentCard else { return }
        let id = card.request.requestId
        hub.decide(requestId: id, allow: allow) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply { $0.requestClosed(id) } }
        }
    }

    func dismissCard() { apply { $0.dismissCard() } }

    // MARK: ряд закреплённых значков

    var pinnedRowCount: Int { icons?.pinnedRow.count ?? 0 }

    /// Значки или закреплённое поменялись: ряд мог появиться, исчезнуть или сменить состав.
    private func iconsChanged() {
        guard presenter.mode == .list else { lastPinnedRowCount = pinnedRowCount; return }
        let count = pinnedRowCount
        recomputeLayout()
        withAnimation(Look.reduceMotion ? nil : .easeOut(duration: 0.15)) { objectWillChange.send() }
        if count != lastPinnedRowCount { onLayoutChange?() }
        lastPinnedRowCount = count
    }

    /// Нажать закреплённый значок (спрятанный сворачиванием — после возврата значков).
    func pressPinned(_ entry: MenuBarEntry) { icons?.press(entry) }

    // MARK: ответ на вопрос Claude

    private var currentQuestions: [AskQuestion]? { presenter.currentCard?.request.questions }

    /// Нажат вариант. Вопрос с одним ответом: ответ принят, дальше следующий вопрос или отправка. С несколькими: отметка.
    func askPick(_ label: String) {
        guard let questions = currentQuestions, ask.index < questions.count else { return }
        let question = questions[ask.index]
        guard question.options.contains(where: { $0.label == label }) else { return }
        if question.multiSelect {
            var chosen = ask.picks[question.question] ?? []
            if let i = chosen.firstIndex(of: label) { chosen.remove(at: i) } else { chosen.append(label) }
            ask.picks[question.question] = chosen
            askChanged(resize: false)
        } else {
            ask.picks[question.question] = [label]
            askAdvance()
        }
    }

    /// «Далее» / «Готово» у вопроса с несколькими ответами.
    func askNext() {
        guard let questions = currentQuestions, ask.index < questions.count,
              !(ask.picks[questions[ask.index].question] ?? []).isEmpty else { return }
        askAdvance()
    }

    func askBack() {
        guard ask.index > 0 else { return }
        ask.index -= 1
        askChanged(resize: true)
    }

    private func askAdvance() {
        guard let questions = currentQuestions else { return }
        if ask.index + 1 < questions.count {
            ask.index += 1
            askChanged(resize: true)
        } else {
            submitAsk()
        }
    }

    private func submitAsk() {
        guard let card = presenter.currentCard else { return }
        let id = card.request.requestId
        hub.answer(requestId: id, picks: ask.picks) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply { $0.requestClosed(id) } }
        }
    }

    private func askChanged(resize: Bool) {
        if resize { recomputeLayout() }
        withAnimation(Look.reduceMotion ? nil : .easeOut(duration: 0.15)) { objectWillChange.send() }
        if resize { onLayoutChange?() }
    }

    /// Закрыть все карточки (сон, пропал экран с вырезом): диалоги остаются в терминалах.
    func releaseCards() {
        hub.releaseAllCards()
    }

    // MARK: внутреннее

    private func apply(_ change: (inout IslandPresenter) -> Void) {
        var next = presenter
        change(&next)
        let before = visibleKey(presenter, labels: labels)
        let opensList = presenter.mode != .list && next.mode == .list
        presenter = next
        if opensList, let icons {
            icons.message = nil
            icons.refreshIfStale()
        }
        if ask.requestId != next.currentCardId {
            ask = AskDraft(requestId: next.currentCardId, questionCount: next.currentCard?.request.questions?.count ?? 0)
        }
        recomputeLayout()
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write(Data("[island] mode=\(next.mode) summary=\"\(next.summaryText)\" sessions=\(next.sessions.map { "\($0.project):\($0.status):\($0.hostApp ?? "-")" })\n".utf8))
        }
        // Вид перерисовываем, только если изменилось то, что на нём видно в текущем режиме.
        if visibleKey(next, labels: labels) != before {
            // Смена содержимого (свёрнуто → список → карточка) плавно растворяется; фигуру двигает панель.
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)) {
                objectWillChange.send()
            }
            onLayoutChange?()
        }
    }

    /// Всё, что видно на экране в текущем режиме (в свёрнутом виде это только сводка, в списке — строки, на карточке — запрос).
    private func visibleKey(_ p: IslandPresenter, labels: [String: SessionLabel]) -> [String] {
        switch p.mode {
        case .hidden:
            return ["hidden"]
        case .collapsed:
            return ["collapsed", "\(ears.style)", "\(ears.leftWidth)", "\(ears.rightWidth)", "\(p.mediaActive)"]
                + p.summaryParts.map { "\($0.status.rawValue):\($0.text)" }
        case .list:
            return ["list", "\(p.mediaActive)"] + p.sessions.map {
                "\($0.sessionId)|\(String(describing: labels[$0.sessionId]))|\($0.status.rawValue)|\($0.currentAction)|\($0.hostApp ?? "")|\($0.queue.count)"
            }
        case .card(let id):
            let session = p.currentCard?.session
            return ["card", id, session?.sessionId ?? "", String(describing: labels[session?.sessionId ?? ""]), "\(p.queuedBehindCurrent)", session?.hostApp ?? ""]
        }
    }

    /// События идут потоком (каждый вызов инструмента — два): копим и перерисовываем не чаще раза в 40 мс.
    private func enqueue(_ sessions: [Session]) {
        pendingSessions = sessions
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard let sessions = pendingSessions else { return }
        pendingSessions = nil
        let newLabels = SessionStore.displayLabels(sessions)
        if newLabels != labels {
            labels = newLabels          // сначала подписи, чтобы вид собрался с актуальными названиями
        }
        apply { $0.update(sessions: sessions) }
        if CommandLine.arguments.contains("--debug-open-list"), !sessions.isEmpty, !pinned { toggleList() }
    }

    private func sessionDone(_ session: Session) {
        guard Settings.soundEnabled, !isWatching(session) else { return }
        NSSound(named: "Tink")?.play()
    }
}

/// Свободное место по сторонам выреза (nil — вдоволь).
struct Space: Equatable {
    var left: CGFloat?
    var right: CGFloat?

    /// Совпадает с точностью до пары пунктов (замеры слегка гуляют).
    func same(as other: Space) -> Bool {
        func eq(_ a: CGFloat?, _ b: CGFloat?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x - y) < 2
            default: return false
            }
        }
        return eq(left, other.left) && eq(right, other.right)
    }
}

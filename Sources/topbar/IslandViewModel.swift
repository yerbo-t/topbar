import AppKit
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
    @Published private(set) var titles: [String: String] = [:]
    /// Что играет в системе (nil — ничего) и обложка; положение в треке считает вид сам.
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    private var pausedSince: Date?
    private var pauseTimer: DispatchWorkItem?
    let player = NowPlayingService()
    /// Фигура острова: меняется пружиной, пока окно больше неё (см. `IslandPanelController.layout`).
    @Published var shape = ShapeRect(x: 0, width: 0, height: 0, radius: 11)
    /// Размеры считаются один раз на изменение (замер текста не должен повторяться при каждой перерисовке).
    private(set) var size: CGSize = .zero
    /// Раскладка «ушей» свёрнутого острова: подстраивается под свободное место до значков справа от выреза.
    private(set) var ears = EarLayout(style: .full, left: [], right: [], leftWidth: 110, rightWidth: 110)
    /// Свободное место между вырезом и первым значком справа (nil — значков нет или не удалось узнать).
    private var availableRight: CGFloat?
    private var spaceCheckedAt = Date.distantPast
    private var pendingSessions: [Session]?
    private var flushTask: Task<Void, Never>?
    /// Список раскрыт кликом (остаётся, пока владелец не свернёт); наведением раскрывается временно.
    private var pinned = false
    private var hoverTask: Task<Void, Never>?

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

    func startPlayerIfEnabled() { if Settings.playerEnabled { player.start() } }

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
            applyArtwork(art)
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

    /// Название приложения, откуда играет (Dia, Spotify…).
    var mediaSourceName: String? {
        guard let pid = nowPlaying?.pid, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }

    /// Владелец смотрит на сессию: приложение-хост активно, а для Ghostty — ещё и терминал сессии в фокусе.
    func isWatching(_ session: Session) -> Bool {
        let front = system.frontmostBundleId
        let focused = (front == GhosttyScripting.bundleId && session.tty != nil) ? GhosttyScripting.focusedTTY() : nil
        return WatchPolicy.isWatching(session, frontmostBundleId: front, ghosttyFocusedTTY: focused)
    }

    var mode: IslandMode { presenter.mode }

    /// Можно перезапустить приложение (для обновления): нет открытых карточек и сессий, ждущих разрешения.
    var canRestartNow: Bool {
        presenter.currentCardId == nil && !presenter.sessions.contains { $0.status == .waitingPermission }
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
            return EarLayout(style: .compact, left: [], right: [], leftWidth: width, rightWidth: min(width, availableRight ?? width))
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return EarLayout.make(chips: presenter.summaryChips, availableRight: availableRight) {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    /// Узнать, сколько места до первого значка справа от выреза. true — место изменилось и остров надо пересобрать.
    /// Значки меняются сами по себе (SwiftBar меняет заголовок, приложения добавляют и убирают значки), поэтому
    /// пока остров свёрнут, это проверяется раз в пару секунд.
    @discardableResult
    func refreshMenuBarSpace(force: Bool = false) -> Bool {
        guard let geometry else { return false }
        if !force, Date().timeIntervalSince(spaceCheckedAt) < 0.5 { return false }
        spaceCheckedAt = Date()
        var sample = MenuBarLayout.freeSpaceRightOfNotch(on: geometry.screen, notchWidth: geometry.notchWidth)
        // Отладка: подставить свободное место (`--debug-free-right 36`), чтобы проверить виды ушей без значков.
        if let i = CommandLine.arguments.firstIndex(of: "--debug-free-right"), i + 1 < CommandLine.arguments.count,
           let value = Double(CommandLine.arguments[i + 1]) { sample = .points(CGFloat(value)) }
        let free: CGFloat?
        switch sample {
        case .unknown: return false           // строка спрятана: остаёмся при последнем известном месте
        case .unlimited: free = nil
        case .points(let value): free = value
        }
        let changed: Bool
        switch (free, availableRight) {
        case (nil, nil): changed = false
        case let (a?, b?): changed = abs(a - b) >= 2
        default: changed = true
        }
        if changed { availableRight = free; recomputeLayout() }
        return changed
    }

    /// Сдвиг центра окна от середины экрана: свёрнутый остров может быть несимметричным (справа места мало).
    var centerShift: CGFloat {
        presenter.mode == .collapsed ? (ears.rightWidth - ears.leftWidth) / 2 : 0
    }

    /// Радиус нижних углов: у свёрнутого острова — как у выреза, у раскрытого — мягче.
    var cornerRadius: CGFloat { presenter.mode == .collapsed ? 11 : 22 }

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
            return CGSize(width: Self.listWidth, height: notchH + 10 + player + rows * 54 + 40)
        case .card:
            guard let card = presenter.currentCard else { return .zero }
            // Оценка числа строк с переносами: ~46 символов моноширинного шрифта в строке карточки.
            let estimated = card.request.detail.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 46.0))) }
            let lines = CGFloat(min(max(estimated, 1), 9))
            let detail = min(max(lines * 16 + 24, 44), 190)
            return CGSize(width: Self.listWidth, height: notchH + 10 + 44 + 22 + detail + 92 + 24)
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

    /// Закрыть все карточки (сон, пропал экран с вырезом): диалоги остаются в терминалах.
    func releaseCards() {
        hub.releaseAllCards()
    }

    // MARK: внутреннее

    private func apply(_ change: (inout IslandPresenter) -> Void) {
        var next = presenter
        change(&next)
        let before = visibleKey(presenter, titles: titles)
        presenter = next
        recomputeLayout()
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write(Data("[island] mode=\(next.mode) summary=\"\(next.summaryText)\" sessions=\(next.sessions.map { "\($0.project):\($0.status):\($0.hostApp ?? "-")" })\n".utf8))
        }
        // Вид перерисовываем, только если изменилось то, что на нём видно в текущем режиме.
        if visibleKey(next, titles: titles) != before {
            // Смена содержимого (свёрнуто → список → карточка) плавно растворяется; фигуру двигает панель.
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)) {
                objectWillChange.send()
            }
            onLayoutChange?()
        }
    }

    /// Всё, что видно на экране в текущем режиме (в свёрнутом виде это только сводка, в списке — строки, на карточке — запрос).
    private func visibleKey(_ p: IslandPresenter, titles: [String: String]) -> [String] {
        switch p.mode {
        case .hidden:
            return ["hidden"]
        case .collapsed:
            return ["collapsed", "\(ears.style)", "\(ears.leftWidth)", "\(ears.rightWidth)", "\(p.mediaActive)"]
                + p.summaryParts.map { "\($0.status.rawValue):\($0.text)" }
        case .list:
            return ["list", "\(p.mediaActive)"] + p.sessions.map {
                "\($0.sessionId)|\(titles[$0.sessionId] ?? $0.project)|\($0.status.rawValue)|\($0.currentAction)|\($0.hostApp ?? "")|\($0.queue.count)"
            }
        case .card(let id):
            let session = p.currentCard?.session
            return ["card", id, session?.sessionId ?? "", titles[session?.sessionId ?? ""] ?? "", "\(p.queuedBehindCurrent)", session?.permissionMode ?? ""]
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
        let newTitles = SessionStore.displayTitles(sessions)
        if newTitles != titles {
            titles = newTitles          // сначала названия, чтобы вид собрался с актуальными подписями
        }
        apply { $0.update(sessions: sessions) }
        if CommandLine.arguments.contains("--debug-open-list"), !sessions.isEmpty, !pinned { toggleList() }
    }

    private func sessionDone(_ session: Session) {
        guard Settings.soundEnabled, !isWatching(session) else { return }
        NSSound(named: "Tink")?.play()
    }
}

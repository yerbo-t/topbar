import AppKit
import SwiftUI
import TopbarCore

/// Связывает хаб сессий с видом: хранит состояние острова и принимает действия владельца.
@MainActor
final class IslandViewModel: ObservableObject {
    @Published private(set) var presenter = IslandPresenter()
    @Published private(set) var titles: [String: String] = [:]
    /// Размеры считаются один раз на изменение (замер текста не должен повторяться при каждой перерисовке).
    private(set) var size: CGSize = .zero
    private(set) var earWidth: CGFloat = 110
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
                guard let self else { return done(false) }
                done(self.system.hasNotchScreen && !self.isWatching(session))
            }
        }
        recomputeLayout()
    }

    /// Владелец смотрит на сессию: приложение-хост активно, а для Ghostty — ещё и терминал сессии в фокусе.
    func isWatching(_ session: Session) -> Bool {
        let front = system.frontmostBundleId
        let focused = (front == GhosttyScripting.bundleId && session.tty != nil) ? GhosttyScripting.focusedTTY() : nil
        return WatchPolicy.isWatching(session, frontmostBundleId: front, ghosttyFocusedTTY: focused)
    }

    var mode: IslandMode { presenter.mode }

    // MARK: размеры

    static let listWidth: CGFloat = 440

    /// Пересчитать размеры; зовётся после каждого изменения состояния и смены экрана.
    func recomputeLayout() {
        earWidth = computeEarWidth()
        size = computeSize()
    }

    /// Ширина «уха» по самому длинному содержимому (оба уха одинаковые, чтобы остров стоял симметрично у выреза).
    private func computeEarWidth() -> CGFloat {
        let parts = presenter.summaryParts
        let left = parts.first.map { [$0] } ?? []
        let right = Array(parts.dropFirst())
        func width(_ items: [(status: SessionStatus, text: String)]) -> CGFloat {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let texts = items.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }
            return texts.reduce(0) { $0 + $1 + 14 } + CGFloat(max(0, items.count - 1)) * 6 + 24
        }
        return max(110, ceil(max(width(left), width(right))))
    }

    private func computeSize() -> CGSize {
        let notchH = geometry?.notchHeight ?? 32
        let notchW = geometry?.notchWidth ?? 200
        switch presenter.mode {
        case .hidden:
            return .zero
        case .collapsed:
            return CGSize(width: notchW + 2 * earWidth, height: notchH)
        case .list:
            let rows = CGFloat(presenter.sessions.count)
            return CGSize(width: Self.listWidth, height: notchH + 10 + rows * 54 + 40)
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
        presenter = next
        recomputeLayout()
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write(Data("[island] mode=\(next.mode) summary=\"\(next.summaryText)\" sessions=\(next.sessions.map { "\($0.project):\($0.status)" })\n".utf8))
        }
        onLayoutChange?()
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
        apply { $0.update(sessions: sessions) }
        titles = SessionStore.displayTitles(sessions)
        if CommandLine.arguments.contains("--debug-open-list"), !sessions.isEmpty, !pinned { toggleList() }
    }

    private func sessionDone(_ session: Session) {
        guard Settings.soundEnabled, !isWatching(session) else { return }
        NSSound(named: "Tink")?.play()
    }
}

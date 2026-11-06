import AppKit
import TopbarCore

/// Сворачивание значков строки меню одной кнопкой (способ Hidden Bar).
///
/// Значки лежат в строке справа налево. У приложения два значка: видимый знак topbar (его создаёт `MenuController`) и невидимый
/// «выталкиватель» впритык слева от него. В свёрнутом виде выталкиватель становится очень длинным; система не может его
/// разместить и убирает вместе со всем, что левее. Значит, прячется всё левее знака topbar. Знак остаётся на виду. Чтобы часть
/// значков осталась на экране, владелец один раз переносит знак левее них (⌘ + перетаскивание); выталкиватель сам встаёт рядом.
/// Ничего не нужно узнавать про чужие значки, поэтому не нужны и разрешения.
@MainActor
final class MenuBarHider {
    enum Toggle { case changed, nothingToHide }

    /// Длина выталкивателя в свёрнутом виде. Система сама обрезает её (на этом Mac — до ~5000), но и этого хватает.
    static let hiddenLength: CGFloat = 10000

    /// Имена для сохранения положения значков. Пока владелец их не двигал, знак ставится у правого края (рядом с «Пунктом
    /// управления»): на Mac с вырезом слева места нет, система роняет самые левые значки, а новые по умолчанию встают
    /// именно слева — и знак просто не был бы виден.
    static let controlName = "topbar-control"
    private static let pusherName = "topbar-pusher"
    private static let seedControl = 40.0
    private static let collapsedKey = "menuBarCollapsed"
    private static func positionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    /// Задать начальное положение знака, если владелец ещё не двигал значок, и убрать следы прежнего разделителя. Вызывать до
    /// создания значка.
    static func seedPositions() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: positionKey(controlName)) == nil { defaults.set(seedControl, forKey: positionKey(controlName)) }
        for old in [positionKey("topbar-separator"), "NSStatusItem Visible topbar-separator", "menuBarBaselineRight"] {
            defaults.removeObject(forKey: old)
        }
    }

    private weak var control: NSStatusItem?
    private var pusher: NSStatusItem?
    private var resync: DispatchWorkItem?
    private var syncedControlPosition: Double?
    private var watchdog: Timer?
    private var misalignedChecks = 0
    private var settleToken = 0
    /// Сколько значков между выталкивателем и знаком сторож уже пытался убрать пересозданием (дальше принимает как есть).
    private var repairedStrayCount = 0
    private var settleAttempts = 0
    private var rebuildTimes: [Date] = []
    private var moveObserver: NSObjectProtocol?
    private(set) var isEnabled = false
    private(set) var isCollapsed = false

    /// Состояние поменялось (обновить вид знака).
    var onStateChange: (() -> Void)?
    /// Сворачивание отменено: знак оказался там, где система не может его показать, и пропал бы вместе со всем остальным.
    var onSafetyRevert: (() -> Void)?

    func enable(control: NSStatusItem) {
        guard !isEnabled else { return }
        self.control = control
        isEnabled = true
        isCollapsed = false
        rebuildPusher()
        // Выталкиватель должен стоять впритык слева от знака и после того, как владелец перенесёт знак.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: control.button?.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controlMoved() }
        }
        startWatchdog()
        onStateChange?()
        // Если в прошлый раз значки были спрятаны — прячем и сейчас, когда система разложила значки. Строка меню может быть
        // спрятана (полный экран) — тогда повторяем позже. Сами по себе значки больше не прячутся: только по клику владельца.
        guard UserDefaults.standard.bool(forKey: Self.collapsedKey) else { return }
        for delay in [0.8, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isEnabled, !self.isCollapsed, (self.itemsToHide() ?? 0) > 0 else { return }
                self.collapseAligned()
            }
        }
    }

    func disable() {
        watchdog?.invalidate()
        watchdog = nil
        resync?.cancel()
        if let token = moveObserver { NotificationCenter.default.removeObserver(token); moveObserver = nil }
        if let item = pusher { NSStatusBar.system.removeStatusItem(item); pusher = nil }
        isEnabled = false
        isCollapsed = false
        onStateChange?()
    }

    /// Клик по кнопке «Спрятать / Показать значки». `.nothingToHide` — левее знака пусто: ничего не прячем, объясняем.
    func toggle() -> Toggle {
        guard isEnabled else { return .changed }
        if isCollapsed {
            setCollapsed(false)
            return .changed
        }
        // nil — строка меню сейчас спрятана (полноэкранное окно), значков не разглядеть: считаем, что прятать есть что.
        if let count = itemsToHide(), count == 0 { return .nothingToHide }
        collapseAligned()
        return .changed
    }

    /// Свернуть, предварительно поставив выталкиватель впритык к знаку: иначе спрячется только часть значков или ни одного.
    /// В развёрнутом виде выталкивателя в строке нет, поэтому на время проверки он показывается узким.
    private func collapseAligned() {
        // Новый значок система ставит на сохранённое место надёжнее, чем сдвигает старый, поэтому выталкиватель создаётся заново.
        recreatePusher()
        settlePusher(allowRebuild: true) { [weak self] ok in
            guard let self, self.isEnabled, !self.isCollapsed else { return }
            if !ok { Self.trace("выталкиватель не встал впритык к знаку за 3 с, сворачиваю как есть (сторож поправит)") }
            self.setCollapsed(true)
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isEnabled, collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        repairedStrayCount = 0
        Self.trace(collapsed ? "значки свёрнуты" : "значки показаны")
        UserDefaults.standard.set(collapsed, forKey: Self.collapsedKey)
        applyLength()
        if collapsed {
            // Если знак оказался левее выталкивателя, он уехал за экран вместе со всем остальным — вернём всё.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.isCollapsed, !self.controlIsOnScreen() else { return }
                self.setCollapsed(false)
                self.onSafetyRevert?()
            }
        }
        onStateChange?()
    }

    // MARK: выталкиватель рядом со знаком

    private var controlPosition: Double? {
        UserDefaults.standard.object(forKey: Self.positionKey(Self.controlName)) as? Double
    }

    /// Пересоздать выталкиватель сразу левее знака. Свёрнуто — дождаться, пока он встанет впритык (спрятанные значки на это
    /// время на долю секунды показываются), и вернуть длинным; развёрнуто — просто убрать из строки: место ему нужно только при сворачивании,
    /// и `collapseAligned` создаёт его заново.
    private func rebuildPusher() {
        recreatePusher()
        guard isCollapsed else { applyLength(); return }
        settlePusher(allowRebuild: true) { [weak self] ok in
            if !ok { Self.trace("пересозданный выталкиватель не встал впритык к знаку за 3 с") }
            self?.applyLength()
        }
    }

    /// Новый выталкиватель сразу левее знака: положение значка система берёт из настроек при создании.
    private func recreatePusher() {
        if let old = pusher { NSStatusBar.system.removeStatusItem(old) }
        let position = (controlPosition ?? Self.seedControl) + 1
        UserDefaults.standard.set(position, forKey: Self.positionKey(Self.pusherName))
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = Self.pusherName
        item.isVisible = true
        pusher = item
        syncedControlPosition = controlPosition
    }

    /// Новый значок система ставит на сохранённое место через долю секунды (видно, как он «доезжает»), иногда не сразу. Ждём, пока зазор
    /// между выталкивателем и знаком не станет нулевым; пока ждём, подталкиваем длиной (1 ↔ 2), а если за ~0,9 с не встал — создаём
    /// заново (до двух раз). Всего до ~2,7 с; `done(false)` — так и не встал.
    private func settlePusher(allowRebuild: Bool, done: @escaping (Bool) -> Void) {
        settleToken += 1
        settleAttempts = 0
        settleStep(settleToken, allowRebuild: allowRebuild, done: done)
    }

    private func settleStep(_ token: Int, allowRebuild: Bool, done: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, token == self.settleToken, self.isEnabled else { return }
            self.settleAttempts += 1
            let gap = self.gapBetweenPusherAndControl()
            Self.trace("выталкиватель: попытка \(self.settleAttempts), зазор до знака \(gap.map(String.init) ?? "?")")
            if let gap, abs(gap) <= 4 { done(true); return }
            if self.settleAttempts >= 18 { done(false); return }
            if allowRebuild, self.settleAttempts % 6 == 0 {
                self.recreatePusher()
            } else {
                self.pusher?.length = self.settleAttempts % 2 == 0 ? 1 : 2
            }
            self.settleStep(token, allowRebuild: allowRebuild, done: done)
        }
    }

    private static func trace(_ text: String) {
        guard CommandLine.arguments.contains("--debug") else { return }
        FileHandle.standardError.write(Data("[hider] \(text)\n".utf8))
    }

    /// Знак сдвинули (владелец перетащил или система переложила значки): когда он остановится, подвинуть выталкиватель.
    private func controlMoved() {
        guard isEnabled else { return }
        resync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled, self.controlPosition != self.syncedControlPosition else { return }
            self.rebuildPusher()
        }
        resync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: сторож: выталкиватель должен стоять впритык слева от знака

    /// Раз в полторы секунды проверяет, что между выталкивателем и знаком нет чужих значков. Если есть (владелец перетащил знак ⌘
    /// туда и обратно, система переложила значки), выталкиватель пересоздаётся рядом со знаком. Это страховка к быстрому пути в
    /// `controlMoved`, который опирается на сохранённые положения, а система их может переписать сама.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Рамки значков между выталкивателем и знаком; nil — проверить нельзя (строка меню спрятана, окон нет).
    private func iconsBetweenPusherAndControl() -> [CGRect]? {
        guard let cw = control?.button?.window, let pw = pusher?.button?.window, let screen = cw.screen ?? NSScreen.main else { return nil }
        let frames = MenuBarLayout.statusItemFrames(on: screen)
        guard !frames.isEmpty else { return nil }
        return frames.filter { frame in
            !PusherPlacement.sameHorizontalRange(frame, cw.frame) && !PusherPlacement.sameHorizontalRange(frame, pw.frame)
                && frame.width > 2 && frame.minX >= pw.frame.maxX - 2 && frame.maxX <= cw.frame.minX + 2
        }
    }

    private func watchdogTick() {
        guard isEnabled else { return }
        // Идёт перетаскивание (кнопка мыши зажата): не мешаем, дождёмся конца.
        if NSEvent.pressedMouseButtons != 0 { misalignedChecks = 0; return }
        // Знак оказался там, где его не видно, пока значки спрятаны, — вернуть всё, иначе до знака не добраться.
        if isCollapsed, !controlIsOnScreen() {
            setCollapsed(false)
            onSafetyRevert?()
            return
        }
        // В развёрнутом виде выталкивателя в строке нет, и его место проверяется перед сворачиванием; сторож нужен свёрнутому.
        guard isCollapsed else { misalignedChecks = 0; return }
        let strayIcons = iconsBetweenPusherAndControl()?.count ?? 0
        // Системные значки (индикатор микрофона и т. п.) система ставит между выталкивателем и знаком сама, и спрятать их нельзя:
        // после одного пересоздания, которое их не убрало, они принимаются как есть, иначе спрятанные значки мигали бы каждые 3 с.
        if strayIcons == 0 { repairedStrayCount = 0 }
        guard strayIcons > repairedStrayCount else { misalignedChecks = 0; return }
        // Два раза подряд (≈3 с): это не мимолётный сдвиг при перестановке.
        misalignedChecks += 1
        guard misalignedChecks >= 2 else { return }
        misalignedChecks = 0
        // Не больше трёх пересозданий в минуту: если система упорно ставит иначе, не крутимся по кругу.
        rebuildTimes.removeAll { Date().timeIntervalSince($0) > 60 }
        guard rebuildTimes.count < 3 else { return }
        rebuildTimes.append(Date())
        repairedStrayCount = strayIcons
        FileHandle.standardError.write(Data("[hider] выталкиватель стоял не у знака (между ними значков: \(strayIcons)), переставляю\n".utf8))
        rebuildPusher()
    }

    // MARK: самопроверка (`--debug-hider-selftest`)

    /// Прогон без участия владельца: сворачивание, возврат и проверка, что само ничего не сворачивается. Результат — в stderr. Строка меню должна быть
    /// видна (иначе не разглядеть значки): в полноэкранном режиме подведите мышь к верхнему краю.
    func selfTest() {
        func log(_ text: String) { FileHandle.standardError.write(Data("[hider-selftest] \(text)\n".utf8)) }
        func frames(_ label: String) {
            let c = control?.button?.window?.frame ?? .zero, p = pusher?.button?.window?.frame ?? .zero
            let visible = NSScreen.main.map { MenuBarLayout.statusItemFrames(on: $0).count } ?? -1
            log("\(label): collapsed=\(isCollapsed) | знак x=\(Int(c.minX)) w=\(Int(c.width)) на экране=\(controlIsOnScreen()) | выталкиватель x=\(Int(p.minX)) w=\(Int(p.width)) | значков в строке=\(visible), левее знака=\(itemsToHide().map(String.init) ?? "?")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            frames("старт")
            _ = toggle()      // тот же путь, что у клика по знаку: проверка места выталкивателя, потом сворачивание
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [self] in
                frames("после сворачивания (знак должен остаться на экране, значков в строке меньше, левее знака 0)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
                    setCollapsed(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                        frames("после разворачивания")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [self] in
                            frames("через 12 с (само не сворачивается: должно остаться развёрнутым)")
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    /// Зазор между правым краем выталкивателя и левым краем знака (0 — впритык); nil — окон нет.
    private func gapBetweenPusherAndControl() -> Int? {
        guard let cw = control?.button?.window, let pw = pusher?.button?.window else { return nil }
        return Int(cw.frame.minX - pw.frame.maxX)
    }

    /// Самопроверка размещения (`--debug-hider-misalign-selftest`): выталкиватель нарочно уводится далеко влево от знака (как после
    /// перетаскивания знака ⌘ туда и обратно), значки сворачиваются кликом — перед этим он должен встать на место, — потом
    /// разворачиваются, и выталкивателя в строке быть не должно. Печатает зазор до знака (0 — впритык) и число значков в строке.
    func selfTestMisaligned() {
        func log(_ text: String) { FileHandle.standardError.write(Data("[hider-misalign] \(text)\n".utf8)) }
        func bar() -> Int { NSScreen.main.map { MenuBarLayout.statusItemFrames(on: $0).count } ?? -1 }
        func after(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
        after(2.0) { [self] in
            log("старт: развёрнуто, выталкиватель в строке: \(pusher?.isVisible ?? false), значков в строке \(bar())")
            // Поломка: выталкиватель на 170 пунктов левее знака, узкий и видимый.
            if let old = pusher { NSStatusBar.system.removeStatusItem(old) }
            UserDefaults.standard.set((controlPosition ?? Self.seedControl) + 170, forKey: Self.positionKey(Self.pusherName))
            let broken = NSStatusBar.system.statusItem(withLength: 1)
            broken.autosaveName = Self.pusherName
            pusher = broken
            after(0.7) { [self] in
                log("сломано: зазор до знака \(gapBetweenPusherAndControl().map(String.init) ?? "?") (сильно больше нуля)")
                _ = toggle()
                after(2.2) { [self] in
                    log("после сворачивания кликом: collapsed=\(isCollapsed), значков в строке \(bar()) (при здоровом сворачивании на этом Mac их 7)")
                    setCollapsed(false)
                    after(1.2) { [self] in
                        log("после разворачивания: collapsed=\(isCollapsed), выталкиватель в строке: \(pusher?.isVisible ?? false) (должен быть false), значков в строке \(bar())")
                        exit(0)
                    }
                }
            }
        }
    }

    // MARK: внутреннее

    /// Свёрнуто: выталкиватель в строке и очень длинный. Развёрнуто: убран из строки совсем, иначе его отступы оставляли бы
    /// заметный пробел слева от знака.
    private func applyLength() {
        guard let pusher else { return }
        if isCollapsed {
            pusher.isVisible = true
            pusher.length = Self.hiddenLength
        } else {
            pusher.length = 0
            pusher.isVisible = false
        }
    }

    /// Сколько значков лежит левее выталкивателя в видимой части строки; nil — строка меню не видна (полноэкранное окно).
    /// Считается только в развёрнутом виде.
    private func itemsToHide() -> Int? {
        // Считаем от знака: выталкиватель в развёрнутом виде убран из строки, его окно стоит за краем экрана.
        guard let window = control?.button?.window, let screen = window.screen ?? NSScreen.main else { return nil }
        let frames = MenuBarLayout.statusItemFrames(on: screen)
        guard !frames.isEmpty else { return nil }
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX   // правый край выреза
        return frames.filter { $0.maxX <= window.frame.minX + 1 && $0.minX >= notchRight - 1 }.count
    }

    private func controlIsOnScreen() -> Bool {
        guard let frame = control?.button?.window?.frame, let screen = control?.button?.window?.screen ?? NSScreen.main else { return true }
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        return frame.minX >= notchRight - 1 && frame.maxX <= screen.frame.maxX + 1
    }
}

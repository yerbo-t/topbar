import AppKit

/// Сворачивание значков строки меню одной кнопкой (способ Hidden Bar).
///
/// Приложение держит два значка: управляющий (его рисует `MenuController`) и разделитель. Значки лежат в строке справа
/// налево, и когда разделитель становится очень длинным, всё, что левее него, выталкивается за край экрана. Владелец один раз
/// перетаскивает с зажатым ⌘ нужные значки левее разделителя — дальше клик прячет их и возвращает. Ничего не нужно
/// узнавать про чужие значки, поэтому не нужны и разрешения.
@MainActor
final class MenuBarHider {
    enum Toggle { case changed, needsSetup }

    /// Длина разделителя в свёрнутом виде. Система сама обрезает её (на этом Mac — до ~5000), но и этого хватает.
    static let hiddenLength: CGFloat = 10000
    /// Через сколько секунд развёрнутые значки прячутся сами.
    static let autoCollapseDelay: TimeInterval = 10

    /// Имена для сохранения положения значков. Пока владелец их не двигал, ставим оба у правого края (рядом с «Пунктом
    /// управления»): на Mac с вырезом слева места нет, система роняет самые левые значки, а новые по умолчанию встают
    /// именно слева — и управляющий значок просто не был бы виден.
    static let controlName = "topbar-control"
    static let separatorName = "topbar-separator"

    /// Задать начальные положения, если владелец ещё не двигал значки. Вызывать до создания значков.
    static func seedPositions() {
        let defaults = UserDefaults.standard
        func seed(_ name: String, _ value: Double) {
            let key = positionKey(name)
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        seed(controlName, seedControl)
        seed(separatorName, seedSeparator)
    }

    private static let seedControl = 40.0
    private static let seedSeparator = 41.0   // чуть левее управляющего значка (система поправит до ближайшего допустимого)
    private static func positionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    /// Сколько значков справа от разделителя при первом запуске (системные «Пункт управления» и часы). Положение, которое
    /// система сама записывает вместо начального, для этого не годится — она переписывает его сразу после раскладки.
    private static let baselineKey = "menuBarBaselineRight"

    /// Владелец передвинул разделитель: справа от него появились значки сверх тех, что были при первом запуске.
    /// До этого «свернуть» спрятало бы вообще всё, кроме системных значков. Нет данных (строка меню спрятана) — считаем, что нет.
    var isArranged: Bool {
        guard let baseline = UserDefaults.standard.object(forKey: Self.baselineKey) as? Int,
              let current = itemsRightOfSeparator() else { return false }
        return current > baseline
    }

    private var separator: NSStatusItem?
    private weak var control: NSStatusItem?
    private var autoCollapse: DispatchWorkItem?
    private(set) var isCollapsed = false
    private var startedCollapsedOnce = false

    /// Состояние поменялось (обновить вид управляющего значка).
    var onStateChange: (() -> Void)?
    /// Сворачивание отменено: управляющий значок оказался левее разделителя и пропал бы вместе со всем остальным.
    var onSafetyRevert: (() -> Void)?

    var isEnabled: Bool { separator != nil }

    func enable(control: NSStatusItem) {
        guard separator == nil else { return }
        self.control = control
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.separatorName   // положение, выбранное владельцем, сохраняется
        item.button?.toolTip = "Всё левее этой черты прячется кнопкой topbar (перетаскивайте значки с зажатым ⌘)"
        separator = item
        isCollapsed = false
        applyAppearance()
        // Даём системе разложить значки, запоминаем исходное число значков справа (первый запуск) и, если владелец уже расставил
        // значки, стартуем свёрнутыми. Строка меню может быть спрятана (полный экран) — тогда повторяем позже.
        for delay in [0.6, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.separator != nil, !self.isCollapsed else { return }
                if UserDefaults.standard.object(forKey: Self.baselineKey) == nil, let count = self.itemsRightOfSeparator() {
                    UserDefaults.standard.set(count, forKey: Self.baselineKey)
                }
                if delay == 0.6 || !self.startedCollapsedOnce, self.isArranged, self.itemsToHide() > 0 {
                    self.startedCollapsedOnce = true
                    self.setCollapsed(true)
                }
            }
        }
    }

    func disable() {
        autoCollapse?.cancel()
        if let item = separator { NSStatusBar.system.removeStatusItem(item) }
        separator = nil
        isCollapsed = false
        onStateChange?()
    }

    /// Клик по управляющему значку. `.needsSetup` — значки ещё не расставлены (или левее разделителя пусто):
    /// ничего не прячем, показываем подсказку, как настроить.
    func toggle() -> Toggle {
        guard isEnabled else { return .changed }
        if isCollapsed {
            setCollapsed(false)
            return .changed
        }
        guard isArranged, itemsToHide() > 0 else { return .needsSetup }
        setCollapsed(true)
        return .changed
    }

    func setCollapsed(_ collapsed: Bool) {
        guard separator != nil, collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        applyAppearance()
        autoCollapse?.cancel()
        if collapsed {
            // Если управляющий значок оказался левее разделителя, он уехал за экран вместе со всем остальным — вернём всё.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.isCollapsed, !self.controlIsOnScreen() else { return }
                self.setCollapsed(false)
                self.onSafetyRevert?()
            }
        } else {
            let work = DispatchWorkItem { [weak self] in self?.setCollapsed(true) }
            autoCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCollapseDelay, execute: work)
        }
        onStateChange?()
    }

    /// Продлить показ значков (владелец взаимодействует с ними).
    func extendExpanded() {
        guard !isCollapsed, separator != nil else { return }
        autoCollapse?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setCollapsed(true) }
        autoCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCollapseDelay, execute: work)
    }

    // MARK: самопроверка (`--debug-hider-selftest`)

    /// Прогон без участия владельца: сворачивание, возврат, автосворачивание и защита от значка левее разделителя.
    /// Не требует видимой строки меню (проверяет рамки окон значков), результат — в stderr.
    func selfTest() {
        func log(_ text: String) { FileHandle.standardError.write(Data("[hider-selftest] \(text)\n".utf8)) }
        func frames(_ label: String) {
            let c = control?.button?.window?.frame ?? .zero, s = separator?.button?.window?.frame ?? .zero
            log("\(label): collapsed=\(isCollapsed) control x=\(Int(c.minX)) w=\(Int(c.width)) | separator x=\(Int(s.minX)) w=\(Int(s.width))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            frames("старт")
            setCollapsed(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                frames("после сворачивания (управляющий значок должен остаться на экране)")
                setCollapsed(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    frames("после разворачивания")
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCollapseDelay + 1) { [self] in
                        frames("через \(Int(Self.autoCollapseDelay)) с (должно свернуться само)")
                        // Защита: подставляем значок, созданный позже разделителя, то есть левее него.
                        setCollapsed(false)
                        let stray = NSStatusBar.system.statusItem(withLength: 24)
                        stray.button?.title = "S"
                        control = stray
                        var revertedCalled = false
                        onSafetyRevert = { revertedCalled = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                            setCollapsed(true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                                log("защита: сработала=\(revertedCalled), collapsed=\(isCollapsed) (ожидаем true / false)")
                                NSStatusBar.system.removeStatusItem(stray)
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: внутреннее

    private func applyAppearance() {
        guard let item = separator else { return }
        if isCollapsed {
            item.length = Self.hiddenLength
            item.button?.image = nil
        } else {
            item.length = 8
            item.button?.image = Self.dividerImage
        }
    }

    private static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 8, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 0.75, y: 2, width: 1.5, height: rect.height - 4), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Сколько значков (без управляющего) лежит правее разделителя; nil — строка меню не видна. Только в развёрнутом виде.
    private func itemsRightOfSeparator() -> Int? {
        guard let window = separator?.button?.window, let screen = window.screen ?? NSScreen.main else { return nil }
        let frames = MenuBarLayout.statusItemFrames(on: screen)
        guard !frames.isEmpty else { return nil }
        return max(0, frames.filter { $0.minX >= window.frame.maxX - 1 }.count - 1)
    }

    /// Сколько значков лежит левее разделителя (в видимой части строки). Считается только в развёрнутом виде.
    private func itemsToHide() -> Int {
        guard let window = separator?.button?.window, let screen = window.screen ?? NSScreen.main else { return 0 }
        let frames = MenuBarLayout.statusItemFrames(on: screen)
        let separatorX = window.frame.minX
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX   // правый край выреза
        return frames.filter { $0.maxX <= separatorX + 1 && $0.minX >= notchRight - 1 }.count
    }

    private func controlIsOnScreen() -> Bool {
        guard let frame = control?.button?.window?.frame, let screen = control?.button?.window?.screen ?? NSScreen.main else { return true }
        return frame.minX >= screen.frame.minX && frame.maxX <= screen.frame.maxX + 1
    }
}

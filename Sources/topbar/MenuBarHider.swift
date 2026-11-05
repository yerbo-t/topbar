import AppKit

/// Сворачивание значков строки меню одной кнопкой (способ Hidden Bar).
///
/// Приложение держит два значка: управляющий (его рисует `MenuController`) и разделитель. Значки лежат в строке справа
/// налево, и когда разделитель становится очень длинным, всё, что левее него, выталкивается за край экрана. Владелец один раз
/// перетаскивает с зажатым ⌘ нужные значки левее разделителя — дальше клик прячет их и возвращает. Ничего не нужно
/// узнавать про чужие значки, поэтому не нужны и разрешения.
@MainActor
final class MenuBarHider {
    enum Toggle { case changed, nothingToHide }

    /// Длина разделителя в свёрнутом виде. Система сама обрезает её (на этом Mac — до ~5000), но и этого хватает.
    static let hiddenLength: CGFloat = 10000
    /// Через сколько секунд развёрнутые значки прячутся сами.
    static let autoCollapseDelay: TimeInterval = 10

    private var separator: NSStatusItem?
    private weak var control: NSStatusItem?
    private var autoCollapse: DispatchWorkItem?
    private(set) var isCollapsed = false

    /// Состояние поменялось (обновить вид управляющего значка).
    var onStateChange: (() -> Void)?
    /// Сворачивание отменено: управляющий значок оказался левее разделителя и пропал бы вместе со всем остальным.
    var onSafetyRevert: (() -> Void)?

    var isEnabled: Bool { separator != nil }

    func enable(control: NSStatusItem) {
        guard separator == nil else { return }
        self.control = control
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "topbar-separator"   // положение, выбранное владельцем, сохраняется
        item.button?.toolTip = "Всё левее этой черты прячется кнопкой topbar (перетаскивайте значки с зажатым ⌘)"
        separator = item
        isCollapsed = false
        applyAppearance()
        // Стартуем свёрнутыми: сначала даём системе разложить значки, потом проверяем безопасность.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.separator != nil, !self.isCollapsed else { return }
            if self.itemsToHide() > 0 { self.setCollapsed(true) }
        }
    }

    func disable() {
        autoCollapse?.cancel()
        if let item = separator { NSStatusBar.system.removeStatusItem(item) }
        separator = nil
        isCollapsed = false
        onStateChange?()
    }

    /// Клик по управляющему значку. `.nothingToHide` — левее разделителя нет значков, показываем подсказку, как настроить.
    func toggle() -> Toggle {
        guard isEnabled else { return .changed }
        if isCollapsed {
            setCollapsed(false)
            return .changed
        }
        guard itemsToHide() > 0 else { return .nothingToHide }
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

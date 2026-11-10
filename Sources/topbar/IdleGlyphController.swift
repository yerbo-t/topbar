import AppKit
import TopbarCore

/// Мини-знак topbar в ухе выреза, пока остров скрыт (нет сессий). Клик по нему — то же, что клик по знаку в строке меню:
/// прячет и возвращает значки, правый клик открывает настройку. Работает и в полноэкранном режиме, когда строки меню не видно.
///
/// Окно ровно по ушку, без прозрачных полей: оно перехватывает клики, а слева от выреза лежат меню приложений. Знак стоит
/// слева, а если там нет места (длинные меню), справа; нет и там — знака нет совсем (`IdleGlyph.side`).
@MainActor
final class IdleGlyphController {
    private static let earWidth: CGFloat = 30
    /// Запас до меню приложения или значка, чтобы ушко не стояло вплотную.
    private static let margin: CGFloat = 6
    /// Ушко заходит под вырез: так между ними не бывает светлой щели.
    private static let overlap: CGFloat = 2

    private let panel: NSPanel
    private let view = IdleGlyphView()
    private weak var menu: MenuController?
    private var islandHidden = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(menu: MenuController) {
        self.menu = menu
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.contentView = view
        view.onClick = { [weak self] secondary in self?.clicked(secondary: secondary) }
        refreshImage()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Другое приложение — другие меню слева от выреза: место перемеряем сразу и ещё раз чуть позже, когда меню нового
        // приложения прочитаются. Знак, которому места не хватило, пропадает сразу.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
                for delay in [0.5, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.update() } }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }

    /// Остров скрыт (true) — знак показывается; остров появился (false) — знак уходит, ушки острова его заменяют.
    func setIslandHidden(_ hidden: Bool) {
        guard hidden != islandHidden else { return }
        islandHidden = hidden
        update()
    }

    /// Вид знака (закрашенный — значки спрятаны) и подсказка — как у знака в строке меню.
    func refreshImage() {
        guard let menu else { return }
        view.glyph.image = ControlIcon.image(filled: menu.glyphIsFilled)
        view.toolTip = menu.glyphTip
    }

    private func update() {
        guard islandHidden, let geometry = NotchGeometry.find() else { place(nil, in: nil); return }
        let needed = Double(Self.earWidth + Self.margin)
        let left = Self.free(MenuBarLayout.freeSpaceLeftOfNotch(on: geometry.screen, notchWidth: geometry.notchWidth))
        let right = Self.free(MenuBarLayout.freeSpaceRightOfNotch(on: geometry.screen, notchWidth: geometry.notchWidth))
        place(IdleGlyph.side(freeLeft: left, freeRight: right, needed: needed), in: geometry)
    }

    private static func free(_ space: MenuBarLayout.FreeSpace) -> Double? {
        switch space {
        case .unknown: return nil
        case .unlimited: return .infinity
        case .points(let value): return Double(value)
        }
    }

    private func place(_ side: IdleGlyph.Side?, in geometry: NotchGeometry?) {
        guard let side, let geometry else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let screen = geometry.screen.frame
        let width = Self.earWidth + Self.overlap
        let x = side == .left ? screen.midX - geometry.notchWidth / 2 - Self.earWidth : screen.midX + geometry.notchWidth / 2 - Self.overlap
        let frame = NSRect(x: x, y: screen.maxY - geometry.notchHeight, width: width, height: geometry.notchHeight)
        view.configure(side: side, overlap: Self.overlap)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.alphaValue = animated ? 0 : 1
            panel.orderFrontRegardless()
            if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 } }
        }
    }

    private func clicked(secondary: Bool) {
        menu?.glyphClicked(anchoredTo: panel.frame, secondary: secondary)
    }
}

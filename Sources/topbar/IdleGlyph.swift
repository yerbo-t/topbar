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

/// Ушко: чёрная фигура со скруглённым нижним внешним углом, как у ушей острова, и знак по центру.
@MainActor
final class IdleGlyphView: NSView {
    let glyph = NSImageView()
    var onClick: ((Bool) -> Void)?
    private var side = IdleGlyph.Side.left
    private var overlap: CGFloat = 0
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        addSubview(glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func configure(side: IdleGlyph.Side, overlap: CGFloat) {
        self.side = side
        self.overlap = overlap
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let size = ControlIcon.size
        // Знак по центру видимой части: заходящая под вырез полоска в счёт не идёт.
        let visibleX = side == .left ? 0 : overlap
        let visibleWidth = bounds.width - overlap
        glyph.frame = NSRect(x: visibleX + (visibleWidth - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 11
        // Прямоугольник вылезает за верх и внутрь выреза: скруглённым остаётся только нижний внешний угол.
        let rect = side == .left
            ? NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width + 2 * radius, height: bounds.height + 2 * radius)
            : NSRect(x: bounds.minX - 2 * radius, y: bounds.minY, width: bounds.width + 2 * radius, height: bounds.height + 2 * radius)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?(event.modifierFlags.contains(.control)) }
    override func rightMouseDown(with event: NSEvent) { onClick?(true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { glyph.contentTintColor = .white }
    override func mouseExited(with event: NSEvent) { glyph.contentTintColor = NSColor.white.withAlphaComponent(0.85) }
}

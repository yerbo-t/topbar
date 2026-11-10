import AppKit
import TopbarCore

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
        guard side != self.side || overlap != self.overlap else { return }
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

    /// Клики принимает само ушко, а не картинка внутри: картинка (NSControl) съела бы их и никому не передала.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

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

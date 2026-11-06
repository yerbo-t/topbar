import AppKit

/// Знак приложения в строке меню: плашка-вырез сверху и ножка, как на значке приложения. Закрашенный — значки спрятаны,
/// контурный — показаны.
enum ControlIcon {
    static let size = NSSize(width: 18, height: 16)

    @MainActor static func image(filled: Bool) -> NSImage { filled ? filledImage : outlineImage }

    @MainActor private static let filledImage = draw(filled: true)
    @MainActor private static let outlineImage = draw(filled: false)

    /// Рисует знак (шаблонное изображение: цвет подбирает система под светлую и тёмную строку меню).
    @MainActor private static func draw(filled: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let k = rect.width / 18
            let line = 1.3 * k
            func shape(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
                let r = filled ? r : r.insetBy(dx: line / 2, dy: line / 2)
                return NSBezierPath(roundedRect: r, xRadius: radius * k, yRadius: radius * k)
            }
            let plate = shape(NSRect(x: 1 * k, y: 10 * k, width: 16 * k, height: 6 * k), 2.2)
            let stem = shape(NSRect(x: 6 * k, y: 0.5 * k, width: 6 * k, height: 8.5 * k), 1.8)
            NSColor.black.set()
            for path in [plate, stem] {
                if filled { path.fill() } else { path.lineWidth = line; path.stroke() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

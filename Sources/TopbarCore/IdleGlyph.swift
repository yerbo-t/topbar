import Foundation

/// Мини-знак topbar в ухе выреза, пока остров скрыт (нет сессий): откуда взять для него место.
public enum IdleGlyph {
    public enum Side: Equatable { case left, right }

    /// Сторона выреза, где знак никого не накроет: слева (если свободного места хватает), иначе справа. `nil` у стороны — место
    /// неизвестно (например, нет доступа к меню приложения), `.infinity` — никого нет. Нигде не хватает — знака нет совсем.
    public static func side(freeLeft: Double?, freeRight: Double?, needed: Double) -> Side? {
        if let left = freeLeft, left >= needed { return .left }
        if let right = freeRight, right >= needed { return .right }
        return nil
    }
}

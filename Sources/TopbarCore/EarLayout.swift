import CoreGraphics

/// Один пункт сводки: цвет статуса, число и подпись («1 работает»).
public struct SummaryChip: Equatable, Sendable {
    public var status: SessionStatus
    public var count: Int
    public var text: String
}

public enum EarStyle: Equatable, Sendable {
    case full      // ● 1 работает
    case compact   // ● 1
    case dots      // ●
    case merged    // всё в левом ухе, правого нет
}

/// Раскладка «ушей» свёрнутого острова. Ухо не должно накрывать значки строки меню справа от выреза, поэтому вид
/// выбирается по свободному месту: подробный, если места много, иначе компактный.
public struct EarLayout: Equatable, Sendable {
    public var style: EarStyle
    public var left: [SummaryChip]
    public var right: [SummaryChip]
    public var leftWidth: CGFloat
    public var rightWidth: CGFloat
    /// В правом ухе — обложка играющего трека (слева уже слова сессий, музыке остаётся правое ухо).
    public var showsMedia: Bool

    public init(style: EarStyle, left: [SummaryChip], right: [SummaryChip], leftWidth: CGFloat, rightWidth: CGFloat, showsMedia: Bool = false) {
        self.style = style
        self.left = left
        self.right = right
        self.leftWidth = leftWidth
        self.rightWidth = rightWidth
        self.showsMedia = showsMedia
    }

    /// Сколько места правому уху нужно под обложку рядом с пунктами сводки, и ухо из одной обложки.
    public static let mediaSlot: CGFloat = 24
    public static let minThumbEar: CGFloat = 34

    static let minEar: CGFloat = 30
    static let pad: CGFloat = 10
    static let dot: CGFloat = 8

    /// `availableRight` — свободное место между вырезом и первым значком справа (nil — значков нет, места вдоволь).
    /// `measure` — ширина текста (в приложении — по шрифту).
    /// `withMedia` — играет музыка: обложка встаёт в правое ухо, если там хватает места (в левом уже слова).
    public static func make(chips: [SummaryChip], availableRight: CGFloat?, withMedia: Bool = false, measure: (String) -> CGFloat) -> EarLayout {
        var layout = base(chips: chips, availableRight: availableRight, measure: measure)
        guard withMedia, !chips.isEmpty else { return layout }
        let avail = availableRight ?? .greatestFiniteMagnitude
        if layout.right.isEmpty {
            // Справа пусто (один пункт или всё слева): обложка одна в правом ухе.
            guard avail >= minThumbEar else { return layout }
            layout.rightWidth = min(max(layout.rightWidth, minThumbEar), avail)
            layout.showsMedia = true
        } else if layout.rightWidth + mediaSlot <= avail {
            layout.rightWidth += mediaSlot
            layout.showsMedia = true
        }
        return layout
    }

    private static func base(chips: [SummaryChip], availableRight: CGFloat?, measure: (String) -> CGFloat) -> EarLayout {
        // Пункты делятся между ушами поровну (первое ухо получает лишний): остров остаётся примерно симметричным.
        let leftCount = (chips.count + 1) / 2
        let left = Array(chips.prefix(leftCount)), right = Array(chips.dropFirst(leftCount))
        let avail = availableRight ?? .greatestFiniteMagnitude

        func width(_ group: [SummaryChip], _ style: EarStyle) -> CGFloat {
            guard !group.isEmpty else { return 0 }
            let items = group.map { chip -> CGFloat in
                switch style {
                case .full: return dot + 6 + measure(chip.text)
                case .compact, .merged: return dot + 4 + measure("\(chip.count)")
                case .dots: return dot
                }
            }
            return 2 * pad + items.reduce(0, +) + CGFloat(items.count - 1) * (style == .dots ? 6 : 10)
        }

        if right.isEmpty {
            // Один пункт: слева подробно, справа пустая «крышка», не шире свободного места.
            let l = max(minEar, width(left, .full))
            return EarLayout(style: .full, left: left, right: [], leftWidth: l, rightWidth: min(l, avail))
        }
        for style in [EarStyle.full, .compact, .dots] {
            let l = max(minEar, width(left, style)), r = max(minEar, width(right, style))
            guard r <= avail else { continue }
            // Симметрично, если справа хватает места; иначе правое ухо ровно по содержимому.
            let t = max(l, r)
            if t <= avail { return EarLayout(style: style, left: left, right: right, leftWidth: t, rightWidth: t) }
            return EarLayout(style: style, left: left, right: right, leftWidth: l, rightWidth: r)
        }
        return EarLayout(style: .merged, left: chips, right: [], leftWidth: max(minEar, width(chips, .merged)), rightWidth: 0)
    }
}

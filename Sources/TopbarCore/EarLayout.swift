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
    case merged    // всё в одном ухе (обычно левом), другого нет
}

/// Раскладка «ушей» свёрнутого острова. Уши не должны накрывать ни значки строки меню справа от выреза, ни меню приложения
/// слева от него, поэтому вид выбирается по свободному месту с обеих сторон: подробный, если места много, иначе компактный,
/// а если одной стороне совсем тесно — всё уходит в другое ухо.
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

    /// `availableLeft` — свободное место между последним меню приложения и вырезом (nil — неизвестно или вдоволь).
    /// `availableRight` — свободное место между вырезом и первым значком справа (nil — значков нет, места вдоволь).
    /// `measure` — ширина текста (в приложении — по шрифту).
    /// `withMedia` — играет музыка: обложка встаёт в правое ухо, если там хватает места (в левом уже слова).
    public static func make(chips: [SummaryChip], availableLeft: CGFloat? = nil, availableRight: CGFloat?, withMedia: Bool = false, measure: (String) -> CGFloat) -> EarLayout {
        var layout = base(chips: chips, availableLeft: availableLeft, availableRight: availableRight, measure: measure)
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

    static func width(_ group: [SummaryChip], _ style: EarStyle, measure: (String) -> CGFloat) -> CGFloat {
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

    private static func base(chips: [SummaryChip], availableLeft: CGFloat?, availableRight: CGFloat?, measure: (String) -> CGFloat) -> EarLayout {
        // Пункты делятся между ушами поровну (первое ухо получает лишний): остров остаётся примерно симметричным.
        let leftCount = (chips.count + 1) / 2
        let left = Array(chips.prefix(leftCount)), right = Array(chips.dropFirst(leftCount))
        let availL = availableLeft ?? .greatestFiniteMagnitude
        let availR = availableRight ?? .greatestFiniteMagnitude
        func w(_ group: [SummaryChip], _ style: EarStyle) -> CGFloat { max(minEar, width(group, style, measure: measure)) }

        if right.isEmpty {
            // Один пункт: слева (подробно, если влезает), справа пустая «крышка», не шире свободного места.
            for style in [EarStyle.full, .compact, .dots] where w(left, style) <= availL {
                let l = w(left, style)
                return EarLayout(style: style, left: left, right: [], leftWidth: l, rightWidth: min(l, availR))
            }
            // Слева меню приложения вплотную к вырезу: пункт уходит в правое ухо, левого нет.
            for style in [EarStyle.full, .compact, .dots] where w(left, style) <= availR {
                return EarLayout(style: style, left: [], right: left, leftWidth: 0, rightWidth: w(left, style))
            }
            return fallback(chips, availL: availL, availR: availR, measure: measure)
        }
        for style in [EarStyle.full, .compact, .dots] {
            let l = w(left, style), r = w(right, style)
            guard l <= availL, r <= availR else { continue }
            // Симметрично, если с обеих сторон хватает места; иначе каждое ухо ровно по содержимому.
            let t = max(l, r)
            if t <= availL, t <= availR { return EarLayout(style: style, left: left, right: right, leftWidth: t, rightWidth: t) }
            return EarLayout(style: style, left: left, right: right, leftWidth: l, rightWidth: r)
        }
        // Поровну не помещается: всё в одно ухо, сначала в левое, потом в правое.
        let merged = w(chips, .merged)
        if merged <= availL { return EarLayout(style: .merged, left: chips, right: [], leftWidth: merged, rightWidth: 0) }
        if merged <= availR { return EarLayout(style: .merged, left: [], right: chips, leftWidth: 0, rightWidth: merged) }
        return fallback(chips, availL: availL, availR: availR, measure: measure)
    }

    /// Тесно с обеих сторон: числа в том ухе, где места больше (заходят на соседей меньше всего).
    private static func fallback(_ chips: [SummaryChip], availL: CGFloat, availR: CGFloat, measure: (String) -> CGFloat) -> EarLayout {
        let merged = max(minEar, width(chips, .merged, measure: measure))
        if availL >= availR { return EarLayout(style: .merged, left: chips, right: [], leftWidth: merged, rightWidth: 0) }
        return EarLayout(style: .merged, left: [], right: chips, leftWidth: 0, rightWidth: merged)
    }
}

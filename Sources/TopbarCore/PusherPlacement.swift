import CoreGraphics

/// Где должен стоять «выталкиватель» значков (в строке он виден тонкой чертой): впритык слева от знака topbar. Если между ними оказался чужой значок
/// (например, после перетаскивания знака ⌘ туда и обратно), он остаётся на виду при «спрятанных» значках, и сворачивание ведёт
/// себя неправильно.
public enum PusherPlacement {
    /// Выталкиватель стоит впритык к знаку, если между его правым краем и левым краем знака нет других значков.
    /// `others` — рамки значков на экране без окон самого знака и выталкивателя; сравниваются только края по горизонтали.
    public static func isAdjacent(pusherMaxX: Double, glyphMinX: Double, others: [CGRect], tolerance: Double = 2) -> Bool {
        !others.contains { $0.width > 2 && $0.minX >= pusherMaxX - tolerance && $0.maxX <= glyphMinX + tolerance }
    }

    /// Развёрнутая черта стоит не у знака: пересоздавать ли её. Системные значки (индикатор микрофона и т. п.) система ставит между
    /// чертой и знаком сама, и убрать их нельзя: после одного пересоздания, которое их не убрало (`repairedStrayCount`), они
    /// принимаются как есть, иначе черта мигала бы каждые несколько секунд. Зазор без значков между ними чинится всегда.
    public static func needsRepairWhenExpanded(gap: Double, strayIcons: Int, repairedStrayCount: Int, tolerance: Double = 4) -> Bool {
        guard abs(gap) > tolerance else { return false }
        return strayIcons == 0 || strayIcons > repairedStrayCount
    }

    /// Окно «то же самое»: края совпадают с точностью до `tolerance` (так отсеиваются наши собственные окна).
    public static func sameHorizontalRange(_ a: CGRect, _ b: CGRect, tolerance: Double = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
    }
}

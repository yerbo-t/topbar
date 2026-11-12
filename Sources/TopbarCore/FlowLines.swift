import CoreGraphics

/// Раскладка «по строкам с переносом», как текст: элементы идут слева направо, не влезающий начинает новую строку.
public enum FlowLines {
    /// Сколько строк займут элементы шириной `widths` в ширину `available` с промежутком `spacing` (0 — элементов нет).
    /// Элемент шире всей строки занимает строку сам.
    public static func count(_ widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> Int {
        var lines = 0
        var x: CGFloat = 0
        for width in widths {
            if lines == 0 || (x > 0 && x + spacing + width > available) {
                lines += 1
                x = width
            } else {
                x += (x > 0 ? spacing : 0) + width
            }
        }
        return lines
    }
}

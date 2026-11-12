import AppKit
import SwiftUI
import TopbarCore

/// Ряд закреплённых значков строки меню над списком сессий: нажатие нажимает настоящий значок, даже если он спрятан.
/// Подписан заголовком «Закреплённые значки», у каждого значка — его название из строки меню («🟢 Hetzner»), а не только
/// иконка приложения: у SwiftBar и подобных иконка приложения не похожа на сам значок. Не влезают в две строки — одни иконки.
struct PinnedRowView: View {
    @ObservedObject var icons: MenuBarListModel
    let onPress: (MenuBarEntry) -> Void

    var body: some View {
        let entries = icons.pinnedRow
        let plan = PinnedRowMetrics.plan(entries)
        VStack(alignment: .leading, spacing: PinnedRowMetrics.headerGap) {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(45))
                Text("Закреплённые значки")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Look.muted)
            .frame(height: PinnedRowMetrics.headerHeight)
            .accessibilityAddTraits(.isHeader)
            FlowRows(spacing: PinnedRowMetrics.spacing) {
                ForEach(entries) { entry in
                    PinnedIconButton(entry: entry, image: icons.icons[entry.bundleId], named: plan.named) { onPress(entry) }
                }
            }
        }
        .padding(.horizontal, PinnedRowMetrics.hPad)
        .padding(.top, PinnedRowMetrics.top)
        .padding(.bottom, PinnedRowMetrics.bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Размеры ряда: по ним рисуется вид и считается высота острова (замер текста тем же шрифтом, что в виде).
@MainActor
enum PinnedRowMetrics {
    static let hPad: CGFloat = 16
    static let top: CGFloat = 4
    static let headerHeight: CGFloat = 16
    static let headerGap: CGFloat = 7
    static let chipHeight: CGFloat = 30
    static let spacing: CGFloat = 6
    static let bottom: CGFloat = 12
    static let iconSize: CGFloat = 16
    static let titleMax: CGFloat = 120
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// Ширина ряда внутри списка (у списка свои поля по 6 пт).
    static var inner: CGFloat { IslandViewModel.listWidth - 12 - 2 * hPad }

    static func chipWidth(_ entry: MenuBarEntry) -> CGFloat {
        let text = ceil((entry.title as NSString).size(withAttributes: [.font: titleFont]).width)
        return 7 + iconSize + 5 + min(text, titleMax) + 10
    }

    /// С подписями, если влезают в две строки; иначе одни иконки.
    static func plan(_ entries: [MenuBarEntry]) -> (named: Bool, lines: Int) {
        let named = FlowLines.count(entries.map(chipWidth), available: inner, spacing: spacing)
        if named <= 2 { return (true, named) }
        return (false, FlowLines.count(entries.map { _ in chipHeight }, available: inner, spacing: spacing))
    }

    /// Высота ряда целиком (0 — ряда нет).
    static func height(_ entries: [MenuBarEntry]) -> CGFloat {
        let lines = plan(entries).lines
        guard lines > 0 else { return 0 }
        return top + headerHeight + headerGap + CGFloat(lines) * chipHeight + CGFloat(lines - 1) * spacing + bottom
    }
}

/// Строки с переносом: элементы слева направо, не влезающий уходит на следующую строку.
struct FlowRows: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

private struct PinnedIconButton: View {
    let entry: MenuBarEntry
    let image: NSImage?
    let named: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let m = PinnedRowMetrics.self
        Button(action: action) {
            HStack(spacing: 5) {
                icon.frame(width: m.iconSize, height: m.iconSize)
                if named {
                    Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: m.titleMax, alignment: .leading)
                }
            }
            .padding(.leading, 7).padding(.trailing, named ? 10 : 7)
            .frame(height: m.chipHeight)
            .foregroundStyle(Color(white: hovering ? 0.97 : 0.86))
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
            // Значок, который система сейчас не показывает (под вырезом), виден приглушённым: нажатие объяснит почему.
            .opacity(entry.visibility == .underNotch ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hint)
        .accessibilityLabel(entry.title)
        .accessibilityHint("Открыть меню этого значка в строке меню")
    }

    @ViewBuilder private var icon: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Text(String(entry.title.prefix(1))).font(.system(size: 11, weight: .semibold))
        }
    }

    private var hint: String {
        switch entry.visibility {
        case .pushedOff: return "«\(entry.title)» сейчас спрятан: значки вернутся, и откроется его меню"
        case .underNotch: return "«\(entry.title)» не помещается в строке меню справа от выреза"
        case .visible: return "Открыть меню «\(entry.title)» в строке меню"
        }
    }
}

/// Левая часть подвала списка: число сессий, а если нажатый значок не открылся, то причина.
struct ListFooterInfo: View {
    let countText: String?
    @ObservedObject var icons: MenuBarListModel

    var body: some View {
        if let message = icons.message {
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let countText {
            Text(countText)
        }
    }
}

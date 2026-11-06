import AppKit
import SwiftUI
import TopbarCore

/// Ряд закреплённых значков строки меню над списком сессий: нажатие нажимает настоящий значок, даже если он спрятан.
struct PinnedRowView: View {
    static let height: CGFloat = 46
    @ObservedObject var icons: MenuBarListModel
    let onPress: (MenuBarEntry) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(icons.pinnedRow) { entry in
                PinnedIconButton(entry: entry, image: icons.icons[entry.bundleId]) { onPress(entry) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: Self.height)
    }
}

private struct PinnedIconButton: View {
    let entry: MenuBarEntry
    let image: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 22, height: 22)
                } else {
                    Text(String(entry.title.prefix(1))).font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
            // Значок, который система сейчас не показывает (под вырезом), виден приглушённым: нажатие объяснит почему.
            .opacity(entry.visibility == .underNotch ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.visibility == .pushedOff ? "\(entry.title) — сейчас спрятан, нажатие вернёт значки" : entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityHint("Нажать значок в строке меню")
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

import AppKit
import SwiftUI
import TopbarCore

/// Список всех значков строки меню: закреплённые владельцем сверху, остальные ниже.
struct MenuBarListView: View {
    @ObservedObject var model: MenuBarListModel
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            header
            if let version = model.updateVersion {
                Button { model.onUpdate?(); model.onClose?() } label: {
                    Label("Обновить до \(version)", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(prominent: true))
                .padding(.horizontal, 18).padding(.bottom, 10)
                .accessibilityHint("Откроет описание новой версии и предложит установить её")
            }
            if let title = model.hidingTitle {
                Button { model.toggleHiding() } label: {
                    Label(title, systemImage: model.hidingSymbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(prominent: true))
                .padding(.horizontal, 18).padding(.bottom, 10)
                .accessibilityHint("Прячет значки левее знака topbar или возвращает их")
            }
            if !model.trusted {
                accessPrompt
            } else if model.entries.isEmpty {
                Text(model.loading ? "Ищу значки…" : "Значков не найдено")
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.62))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.ordered) { entry in
                            MenuBarRow(model: model, entry: entry)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: Self.listHeight(rows: model.entries.count))
            }
            footer
        }
        .frame(width: Self.width)
        .foregroundStyle(.white)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.10)))
        )
    }

    static func listHeight(rows: Int) -> CGFloat { min(CGFloat(max(rows, 1)) * rowHeight + 8, 400) }

    private var header: some View {
        HStack {
            Text("Значки строки меню").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.trusted, !model.entries.isEmpty {
                Text("\(model.entries.count)" + (model.hiddenCount > 0 ? " · не видно \(model.hiddenCount)" : ""))
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.62))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
    }

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Чтобы увидеть значки других приложений, нужен доступ «Универсальный доступ». Приложение только читает названия значков и нажимает их по вашему клику.")
                .font(.system(size: 12)).foregroundStyle(Color(white: 0.72))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Дать доступ") { model.requestAccess() }
                    .buttonStyle(CardButtonStyle(prominent: true)).fixedSize()
                Button("Открыть настройки") { model.openAccessSettings() }
                    .buttonStyle(CardButtonStyle(prominent: false)).fixedSize()
            }
            Text("Включили, а доступа всё равно нет? После обновления приложения система считает его новым: выделите topbar в списке настроек, нажмите «−» и добавьте заново («+»). Список обновится сам.")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button("Меню") { model.onShowMenu?() }
                Spacer(minLength: 0)
                Button("Закрыть") { model.onClose?() }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color(white: 0.66))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
}

struct MenuBarRow: View {
    /// У системных значков общий значок «Пункта управления» — для знакомых рисуем свой символ.
    static func systemSymbol(for entry: MenuBarEntry) -> String? {
        guard entry.bundleId == "com.apple.controlcenter" else { return nil }
        let key = String(entry.id.dropFirst("com.apple.controlcenter#".count))
        let known = [
            "com.apple.menuextra.battery": "battery.100",
            "com.apple.menuextra.wifi": "wifi",
            "com.apple.menuextra.clock": "clock",
            "com.apple.menuextra.controlcenter": "switch.2",
            "com.apple.menuextra.bluetooth": "dot.radiowaves.left.and.right",
            "com.apple.menuextra.focusmode": "moon.fill",
            "com.apple.menuextra.display": "sun.max",
            "com.apple.menuextra.sound": "speaker.wave.2",
            "com.apple.menuextra.vpn": "lock.shield",
            "com.apple.menuextra.airplay": "airplayvideo",
        ]
        return known[key]
    }

    @ObservedObject var model: MenuBarListModel
    let entry: MenuBarEntry
    @State private var hovering = false

    var body: some View {
        let dimmed = entry.visibility != .visible
        HStack(spacing: 10) {
            Group {
                if let symbol = Self.systemSymbol(for: entry) {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.18)))
                } else if let icon = model.icons[entry.bundleId] {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.2))
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Color(white: 0.62)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if entry.visibility != .visible {
                Text(entry.visibility == .underNotch ? "под вырезом" : "спрятан")
                    .font(.system(size: 10.5)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
            }
            if model.isPinned(entry), hovering {
                Button { model.moveToTop(entry) } label: { Image(systemName: "arrow.up.to.line") }
                    .buttonStyle(.plain).foregroundStyle(Color(white: 0.7)).help("В самый верх")
            }
            Button { model.togglePin(entry) } label: {
                Image(systemName: model.isPinned(entry) ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isPinned(entry) ? Color.white : Color(white: hovering ? 0.7 : 0.35))
            .help(model.isPinned(entry) ? "Открепить" : "Закрепить сверху")
        }
        .padding(.horizontal, 12)
        .frame(height: MenuBarListView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color(white: 0.14) : .clear))
        .opacity(dimmed ? 0.8 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.press(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

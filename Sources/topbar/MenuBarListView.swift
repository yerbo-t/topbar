import AppKit
import SwiftUI
import TopbarCore

/// Список всех значков строки меню: закреплённые сверху, ниже остальные по недавности работы, внизу свёрнутая группа «Скрытые».
struct MenuBarListView: View {
    @ObservedObject var model: MenuBarListModel
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 46
    static let groupHeaderHeight: CGFloat = 36
    static let dividerHeight: CGFloat = 9

    var body: some View {
        VStack(spacing: 0) {
            header
            if let version = model.updateVersion {
                Button { model.onUpdate?(); model.onClose?() } label: {
                    Label("Обновить до \(version)", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .allow))
                .padding(.horizontal, 18).padding(.bottom, 10)
                .accessibilityHint("Откроет описание новой версии и предложит установить её")
            }
            if let title = model.hidingTitle {
                Button { model.toggleHiding() } label: {
                    Label(title, systemImage: model.hidingSymbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .light))
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
                    sectionsView
                        .padding(.horizontal, 6)
                        .animation(Self.rowAnimation, value: model.prefs)
                        .animation(Self.rowAnimation, value: model.hiddenExpanded)
                }
                .frame(height: Self.listHeight(content: model.contentHeight))
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

    static func listHeight(content: CGFloat) -> CGFloat { min(max(content, rowHeight) + 8, 400) }

    static var rowAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
    }

    @ViewBuilder private var sectionsView: some View {
        let sections = model.sections
        VStack(spacing: 0) {
            ForEach(sections.pinned) { MenuBarRow(model: model, entry: $0) }
            if !sections.pinned.isEmpty, !sections.recent.isEmpty {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    .padding(.horizontal, 12).padding(.vertical, (Self.dividerHeight - 1) / 2)
            }
            ForEach(sections.recent) { MenuBarRow(model: model, entry: $0) }
            if !sections.hidden.isEmpty {
                Button { model.toggleHiddenGroup() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(model.hiddenExpanded ? 90 : 0))
                        Text("Убраны из списка (\(sections.hidden.count))").font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color(white: 0.62))
                    .padding(.horizontal, 12)
                    .frame(height: Self.groupHeaderHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(model.hiddenExpanded ? "Свернёт группу убранных значков" : "Покажет убранные из списка значки, чтобы вернуть нужные")
                if model.hiddenExpanded {
                    ForEach(sections.hidden) { MenuBarRow(model: model, entry: $0) }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Значки строки меню").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.trusted, !model.entries.isEmpty {
                Text("\(model.entries.count)" + (model.notVisibleCount > 0 ? " · в строке не видно \(model.notVisibleCount)" : ""))
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
                    .buttonStyle(PillButtonStyle(kind: .light)).fixedSize()
                Button("Открыть настройки") { model.openAccessSettings() }
                    .buttonStyle(PillButtonStyle(kind: .neutral)).fixedSize()
            }
            Text("Включили, а доступа всё равно нет? После обновления приложения система считает его новым: выделите topbar в списке настроек, нажмите «−» и добавьте заново («+»). Список обновится сам.")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Булавка закрепляет значок: он встаёт вверху этого списка и в ряд «Закреплённые значки» на острове, над сессиями. Глаз убирает значок из этого списка. В самой строке меню значки так не двигаются: их переставляют ⌘ + перетаскивание.")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { model.onShowMenu?() } label: { Label("Меню", systemImage: "line.3.horizontal") }
                    .buttonStyle(PillButtonStyle(kind: .neutral, compact: true))
                    .accessibilityHint("Откроет меню приложения: хуки, обновления, автозапуск, выход")
                Spacer(minLength: 0)
                Button { model.onClose?() } label: { Label("Закрыть", systemImage: "xmark") }
                    .buttonStyle(PillButtonStyle(kind: .neutral, compact: true))
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 14)
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
        let hidden = model.isHidden(entry)
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
            if entry.visibility == .underNotch {
                Text("под вырезом")
                    .font(.system(size: 10.5)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
            }
            if model.isPinned(entry), hovering {
                Button { model.moveToTop(entry) } label: { Image(systemName: "arrow.up.to.line") }
                    .buttonStyle(.plain).foregroundStyle(Color(white: 0.7)).help("Поставить первым среди закреплённых в этом списке")
            }
            Button { model.toggleHidden(entry) } label: {
                Image(systemName: hidden ? "eye.slash" : "eye").frame(width: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: hidden ? 0.85 : (hovering ? 0.8 : 0.5)))
            .help(hidden ? "Вернуть значок в список" : "Убрать значок из этого списка (в строке меню он останется)")
            .accessibilityLabel(hidden ? "Вернуть значок \(entry.title)" : "Скрыть значок \(entry.title)")
            Button { model.togglePin(entry) } label: {
                Image(systemName: model.isPinned(entry) ? "pin.fill" : "pin").frame(width: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isPinned(entry) ? Color.white : Color(white: hovering ? 0.8 : 0.5))
            .help(model.isPinned(entry) ? "Открепить: значок уйдёт и с острова" : "Закрепить: значок встанет вверху списка и в ряд на острове")
            .accessibilityLabel(model.isPinned(entry) ? "Открепить значок \(entry.title)" : "Закрепить значок \(entry.title) вверху списка и на острове")
        }
        .padding(.horizontal, 12)
        .frame(height: MenuBarListView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color(white: 0.14) : .clear))
        .opacity(hidden ? 0.55 : (dimmed ? 0.8 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.press(entry) }
        .help(entry.visibility == .pushedOff ? "Сейчас спрятан кнопкой сворачивания значков" : "")
        .accessibilityElement(children: .contain)
    }
}

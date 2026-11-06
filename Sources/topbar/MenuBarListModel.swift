import AppKit
import TopbarCore

/// Данные списка значков строки меню: что нашлось, что закреплено, скрыто глазом, кто недавно был в работе, что нажато.
@MainActor
final class MenuBarListModel: ObservableObject {
    @Published private(set) var entries: [MenuBarEntry] = []
    @Published private(set) var trusted = MenuBarItemsProvider.isTrusted
    @Published private(set) var loading = false
    @Published private(set) var prefs: MenuBarPrefs
    /// Группа «Скрытые» развёрнута.
    @Published private(set) var hiddenExpanded = false
    /// Высота списка поменялась (группа раскрылась или свернулась, значок переехал): панель подгоняет размер.
    var onResize: (() -> Void)?
    /// Короткое сообщение под списком (почему значок не нажался и что делать).
    @Published var message: String?
    private(set) var icons: [String: NSImage] = [:]
    /// Сворачивание значков (кнопка в подвале списка); nil — выключено.
    var hider: MenuBarHider?
    var onNothingToHide: (() -> Void)?
    /// Показать меню приложения (кнопка «Меню» в подвале).
    var onShowMenu: (() -> Void)?
    var onClose: (() -> Void)?
    /// Есть новая версия приложения (nil — нет) и что сделать по кнопке «Обновить».
    @Published var updateVersion: String?
    var onUpdate: (() -> Void)?

    private static let pinnedKey = "menuBarPinned"
    private static let hiddenKey = "menuBarEyeHidden"
    private static let usedKey = "menuBarLastUsed"
    private static let knownAppsKey = "menuBarKnownApps"
    private var activationObserver: NSObjectProtocol?
    /// Приложения, у которых когда-либо находился значок: только их активность учитывается для порядка по недавности.
    private var knownApps: Set<String>
    /// Что стало активным с прошлого открытия списка: в список попадёт при открытии, а не прямо под курсором владельца.
    private var pendingUsed: [String: Double] = [:]

    init() {
        let defaults = UserDefaults.standard
        prefs = MenuBarPrefs(pinned: defaults.stringArray(forKey: Self.pinnedKey) ?? [],
                             hidden: defaults.stringArray(forKey: Self.hiddenKey) ?? [],
                             lastUsed: defaults.dictionary(forKey: Self.usedKey) as? [String: Double] ?? [:])
        knownApps = Set(defaults.stringArray(forKey: Self.knownAppsKey) ?? [])
        // Кто последним был в работе: приложение со значком стало активным.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let id = app?.bundleIdentifier, id != Bundle.main.bundleIdentifier, self.knownApps.contains(id) else { return }
                self.pendingUsed[id] = Date().timeIntervalSince1970
                self.save()
            }
        }
    }

    /// Значок самого topbar или системный: такие в список не попадают.
    static func isSystemOrOwn(_ bundleId: String) -> Bool {
        bundleId == Bundle.main.bundleIdentifier || bundleId.hasPrefix("com.apple.")
    }

    var sections: MenuBarSections { MenuBarOrdering.sections(entries, prefs: prefs) }
    /// В строке меню этих значков сейчас не видно (под вырезом или спрятаны кнопкой сворачивания).
    var notVisibleCount: Int { entries.filter { $0.visibility != .visible }.count }

    /// Высота нарисованного списка (для высоты панели): строки значков, строка «Скрытые» и разделитель закреплённых.
    var contentHeight: CGFloat {
        let s = sections
        var height = CGFloat(s.pinned.count + s.recent.count) * MenuBarListView.rowHeight
        if !s.pinned.isEmpty, !s.recent.isEmpty { height += MenuBarListView.dividerHeight }
        if !s.hidden.isEmpty {
            height += MenuBarListView.groupHeaderHeight
            if hiddenExpanded { height += CGFloat(s.hidden.count) * MenuBarListView.rowHeight }
        }
        return height
    }

    func refresh() {
        for (key, seconds) in pendingUsed { prefs.markUsed(key, at: Date(timeIntervalSince1970: seconds)) }
        pendingUsed = [:]
        trusted = MenuBarItemsProvider.isTrusted
        guard trusted, !loading, let geometry = NotchGeometry.find() else {
            if !MenuBarItemsProvider.isTrusted { entries = [] }
            return
        }
        loading = true
        let notchRight = Double(geometry.screen.frame.midX + geometry.notchWidth / 2)
        let screenMinX = Double(geometry.screen.frame.minX)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = MenuBarItemsProvider.snapshot(notchRight: notchRight, screenMinX: screenMinX)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // В списке только значки обычных приложений. Свои (знак topbar) и системные (часы, батарея, Wi-Fi, «Пункт
                    // управления», раскладка, пароли Apple) не показываем: прятать их нельзя, а в списке они только путали бы.
                    self.entries = found.filter { $0.width > 0 && !Self.isSystemOrOwn($0.bundleId) }
                    self.knownApps.formUnion(found.map(\.bundleId))
                    UserDefaults.standard.set(Array(self.knownApps), forKey: Self.knownAppsKey)
                    for entry in found where self.icons[entry.bundleId] == nil {
                        self.icons[entry.bundleId] = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleId).first?.icon
                    }
                    self.loading = false
                }
            }
        }
    }

    /// Системный запрос доступа (показывается один раз) и сразу окно настроек: повторно система запрос не показывает.
    func requestAccess() {
        MenuBarItemsProvider.requestAccess()
        openAccessSettings()
    }

    func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Доступ могли включить, пока панель открыта: подхватываем сразу и подгружаем значки.
    func recheckAccess() {
        let now = MenuBarItemsProvider.isTrusted
        guard now != trusted else { return }
        trusted = now
        if now { refresh() }
    }

    func isPinned(_ entry: MenuBarEntry) -> Bool { prefs.isPinned(entry.id) }
    func isHidden(_ entry: MenuBarEntry) -> Bool { prefs.isHidden(entry.id) }

    func togglePin(_ entry: MenuBarEntry) { change { $0.togglePin(entry.id) } }
    func moveToTop(_ entry: MenuBarEntry) { change { $0.moveToTop(entry.id) } }
    func toggleHidden(_ entry: MenuBarEntry) { change { $0.toggleHidden(entry.id) } }

    func toggleHiddenGroup() {
        hiddenExpanded.toggle()
        onResize?()
    }

    private func change(_ edit: (inout MenuBarPrefs) -> Void) {
        edit(&prefs)
        save()
        onResize?()
    }

    private func markUsed(_ key: String) {
        prefs.markUsed(key, at: Date())
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(prefs.pinned, forKey: Self.pinnedKey)
        defaults.set(prefs.hidden, forKey: Self.hiddenKey)
        defaults.set(prefs.lastUsed.merging(pendingUsed) { max($0, $1) }, forKey: Self.usedKey)
    }

    /// Нажать значок. Спрятанный кнопкой сворачивания — сначала показать значки; не помещённый системой — объяснить.
    func press(_ entry: MenuBarEntry) {
        message = nil
        markUsed(entry.id)
        if entry.visibility == .pushedOff, let hider, hider.isCollapsed { hider.setCollapsed(false) }
        let delay: TimeInterval = entry.visibility == .pushedOff ? 0.6 : 0
        let id = entry.id, visibility = entry.visibility
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = MenuBarItemsProvider.press(id: id)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if ok { self.onClose?(); return }
                        self.message = switch visibility {
                        case .underNotch: "Система сейчас не показывает этот значок: правее выреза не хватает места. Освободите место — закройте приложение или спрячьте значки."
                        case .pushedOff: "Значок остаётся за краем экрана. Разверните значки кнопкой внизу списка."
                        case .visible: "Не удалось нажать значок: возможно, строка меню сейчас спрятана (полноэкранное окно)."
                        }
                    }
                }
            }
        }
    }

    func toggleHiding() {
        guard let hider else { return }
        if hider.toggle() == .nothingToHide { onNothingToHide?() }
        objectWillChange.send()
    }

    var hidingSymbol: String { (hider?.isCollapsed ?? false) ? "eye" : "eye.slash" }

    var hidingTitle: String? {
        guard let hider, hider.isEnabled else { return nil }
        return hider.isCollapsed ? "Показать значки" : "Спрятать значки"
    }
}

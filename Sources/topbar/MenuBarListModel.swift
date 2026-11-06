import AppKit
import TopbarCore

/// Данные списка значков строки меню: что нашлось, что закреплено сверху, что нажато.
@MainActor
final class MenuBarListModel: ObservableObject {
    @Published private(set) var entries: [MenuBarEntry] = []
    @Published private(set) var trusted = MenuBarItemsProvider.isTrusted
    @Published private(set) var loading = false
    @Published private(set) var pinned: [String]
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

    init() {
        pinned = UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []
    }

    var ordered: [MenuBarEntry] { MenuBarOrdering.order(entries, pinned: pinned) }
    var hiddenCount: Int { entries.filter { $0.visibility != .visible }.count }

    func refresh() {
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
                    self.entries = found.filter { $0.width > 0 }
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

    func isPinned(_ entry: MenuBarEntry) -> Bool { pinned.contains(entry.id) }

    func togglePin(_ entry: MenuBarEntry) {
        pinned = isPinned(entry) ? MenuBarOrdering.unpin(entry.id, from: pinned) : MenuBarOrdering.pin(entry.id, in: pinned)
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    func moveToTop(_ entry: MenuBarEntry) {
        pinned = MenuBarOrdering.pin(entry.id, in: pinned, atTop: true)
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    /// Нажать значок. Спрятанный кнопкой сворачивания — сначала показать значки; не помещённый системой — объяснить.
    func press(_ entry: MenuBarEntry) {
        message = nil
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

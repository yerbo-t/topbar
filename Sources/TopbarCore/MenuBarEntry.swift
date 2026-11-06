import Foundation

/// Где значок строки меню сейчас относительно экрана.
public enum MenuItemVisibility: String, Sendable {
    case visible      // справа от выреза, на экране
    case underNotch   // система не поместила его правее выреза — под вырезом, не показывается
    case pushedOff    // за краем экрана (спрятан кнопкой сворачивания)

    /// Где лежит значок: левее экрана — спрятан, в зоне выреза — не помещается, иначе виден.
    public static func classify(minX: Double, width: Double, notchRight: Double, screenMinX: Double = 0) -> MenuItemVisibility {
        if minX + width <= screenMinX + 1 { return .pushedOff }
        if minX < notchRight - 1 { return .underNotch }
        return .visible
    }
}

/// Значок приложения или системы в строке меню (то, что нашлось через «Универсальный доступ»).
public struct MenuBarEntry: Equatable, Sendable, Identifiable {
    public var id: String           // стабильный ключ: приложение + идентификатор или номер значка
    public var appName: String
    public var bundleId: String
    public var label: String        // подпись значка: описание или заголовок (у SwiftBar — «⚫ Hetzner»), может быть пустой
    public var minX: Double
    public var width: Double
    public var visibility: MenuItemVisibility

    public init(id: String, appName: String, bundleId: String, label: String, minX: Double, width: Double, visibility: MenuItemVisibility) {
        self.id = id
        self.appName = appName
        self.bundleId = bundleId
        self.label = label
        self.minX = minX
        self.width = width
        self.visibility = visibility
    }

    /// Крупная подпись строки: подпись значка, а если её нет — имя приложения.
    public var title: String { label.isEmpty ? appName : label }
    /// Мелкая подпись: имя приложения, если крупная — подпись значка.
    public var subtitle: String? { label.isEmpty || label == appName ? nil : appName }
}

/// Настройки владельца для списка значков: что закреплено (в его порядке), что скрыто глазом, когда значок или его приложение
/// были в работе. Всё это только про список topbar; в самой строке меню значки не трогаются.
public struct MenuBarPrefs: Equatable, Sendable {
    public static let maxRemembered = 300

    public var pinned: [String]
    public var hidden: [String]
    /// Ключ — идентификатор значка или приложения; значение — секунды с эпохи.
    public var lastUsed: [String: Double]

    public init(pinned: [String] = [], hidden: [String] = [], lastUsed: [String: Double] = [:]) {
        self.pinned = pinned
        self.hidden = hidden
        self.lastUsed = lastUsed
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }
    public func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    /// Закрепить (в конец закреплённых) или открепить. Закрепление возвращает значок из скрытых.
    public mutating func togglePin(_ id: String) {
        if isPinned(id) {
            pinned.removeAll { $0 == id }
        } else {
            hidden.removeAll { $0 == id }
            pinned.append(id)
        }
    }

    /// Поставить значок самым верхним среди закреплённых (закрепив, если не закреплён).
    public mutating func moveToTop(_ id: String) {
        hidden.removeAll { $0 == id }
        pinned.removeAll { $0 == id }
        pinned.insert(id, at: 0)
    }

    /// Скрыть значок или вернуть. Скрытие открепляет значок.
    public mutating func toggleHidden(_ id: String) {
        if isHidden(id) {
            hidden.removeAll { $0 == id }
        } else {
            pinned.removeAll { $0 == id }
            hidden.append(id)
        }
    }

    /// Отметить, что значок (или приложение) только что был в работе. Помнятся последние `maxRemembered` ключей.
    public mutating func markUsed(_ key: String, at date: Date) {
        lastUsed[key] = date.timeIntervalSince1970
        guard lastUsed.count > Self.maxRemembered else { return }
        let oldest = lastUsed.sorted { $0.value < $1.value }.prefix(lastUsed.count - Self.maxRemembered)
        for (k, _) in oldest { lastUsed[k] = nil }
    }
}

/// Список значков по группам: закреплённые, остальные по недавности, скрытые.
public struct MenuBarSections: Equatable, Sendable {
    public var pinned: [MenuBarEntry]
    public var recent: [MenuBarEntry]
    public var hidden: [MenuBarEntry]
}

public enum MenuBarOrdering {
    /// Закреплённые — в порядке владельца; остальные — кто последним был в работе (нажат в списке или его приложение стало
    /// активным) выше, у кого истории нет — после них справа налево, как значки лежат в строке меню; скрытые — отдельно.
    /// Ключ, которого сейчас нет среди значков, пропускается; закреплённое важнее скрытого, если в данных оба признака.
    public static func sections(_ entries: [MenuBarEntry], prefs: MenuBarPrefs) -> MenuBarSections {
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var pinned: [MenuBarEntry] = []
        for id in prefs.pinned {
            if let entry = byId[id], seen.insert(id).inserted { pinned.append(entry) }
        }
        let rest = entries.filter { !seen.contains($0.id) }.sorted { $0.minX > $1.minX }
        let hidden = rest.filter { prefs.isHidden($0.id) }
        func used(_ entry: MenuBarEntry) -> Double? {
            [prefs.lastUsed[entry.id], prefs.lastUsed[entry.bundleId]].compactMap { $0 }.max()
        }
        let visible = rest.filter { !prefs.isHidden($0.id) }
        // Устойчивая сортировка: у кого есть история — по ней, остальные остаются в порядке строки меню.
        let withHistory = visible.filter { used($0) != nil }.sorted { used($0)! > used($1)! }
        let withoutHistory = visible.filter { used($0) == nil }
        return MenuBarSections(pinned: pinned, recent: withHistory + withoutHistory, hidden: hidden)
    }
}

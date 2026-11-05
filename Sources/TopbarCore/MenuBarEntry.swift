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

public enum MenuBarOrdering {
    /// Сначала закреплённые владельцем — в его порядке, затем остальные справа налево (ближе к часам — выше), как их видно
    /// в строке меню. Закреплённый ключ, которого сейчас нет, пропускается.
    public static func order(_ entries: [MenuBarEntry], pinned: [String]) -> [MenuBarEntry] {
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [MenuBarEntry] = []
        for id in pinned {
            if let entry = byId[id], seen.insert(id).inserted { result.append(entry) }
        }
        let rest = entries.filter { !seen.contains($0.id) }.sorted { $0.minX > $1.minX }
        return result + rest
    }

    /// Поставить значок в закреплённые (в конец или, с `atTop`, в самый верх); повторное закрепление ничего не дублирует.
    public static func pin(_ id: String, in pinned: [String], atTop: Bool = false) -> [String] {
        var list = pinned.filter { $0 != id }
        if atTop { list.insert(id, at: 0) } else { list.append(id) }
        return list
    }

    public static func unpin(_ id: String, from pinned: [String]) -> [String] { pinned.filter { $0 != id } }
}

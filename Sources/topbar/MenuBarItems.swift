import AppKit
import ApplicationServices
import TopbarCore

/// Список всех значков строки меню через «Универсальный доступ». Окна значков чужих приложений на macOS 26 снаружи
/// не различить (все числятся за «Пунктом управления»), а дерево доступности каждого приложения знает свои значки,
/// их подписи и положение — в том числе те, которые система не поместила правее выреза.
enum MenuBarItemsProvider {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Системный запрос доступа (показывается один раз; дальше владелец включает его в настройках сам).
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Все значки (кроме значков самого приложения). Долго: опрашивает каждое запущенное приложение, звать не с главного потока.
    static func snapshot(notchRight: Double, screenMinX: Double) -> [MenuBarEntry] {
        guard AXIsProcessTrusted() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me && !$0.isTerminated }
        let lock = NSLock()
        var found: [MenuBarEntry] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let entries = self.entries(of: apps[index], notchRight: notchRight, screenMinX: screenMinX)
            guard !entries.isEmpty else { return }
            lock.lock(); found.append(contentsOf: entries); lock.unlock()
        }
        return found
    }

    /// Нажать значок (открывает его меню). false — система не дала: значок сейчас не показан или строка меню спрятана.
    static func press(id: String) -> Bool {
        guard let (bundleId, index) = split(id),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
              let children = extrasChildren(of: app) else { return false }
        // Ключ может быть и идентификатором значка, а не номером: ищем по обоим.
        let target = children.first(where: { attribute($0, "AXIdentifier") as? String == String(id.dropFirst(bundleId.count + 1)) })
            ?? (index.flatMap { $0 < children.count ? children[$0] : nil })
        guard let element = target else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // MARK: внутреннее

    private static func entries(of app: NSRunningApplication, notchRight: Double, screenMinX: Double) -> [MenuBarEntry] {
        guard let children = extrasChildren(of: app) else { return [] }
        var result: [MenuBarEntry] = []
        for (index, child) in children.enumerated() {
            var point = CGPoint.zero, size = CGSize.zero
            guard let pos = attribute(child, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
                  AXValueGetValue(pos as! AXValue, .cgPoint, &point),
                  let dim = attribute(child, kAXSizeAttribute), CFGetTypeID(dim) == AXValueGetTypeID(),
                  AXValueGetValue(dim as! AXValue, .cgSize, &size), size.width > 0 else { continue }
            let title = (attribute(child, kAXTitleAttribute) as? String) ?? ""
            let desc = (attribute(child, kAXDescriptionAttribute) as? String) ?? ""
            let ident = (attribute(child, "AXIdentifier") as? String) ?? ""
            let bundle = app.bundleIdentifier ?? "pid\(app.processIdentifier)"
            result.append(MenuBarEntry(
                id: bundle + "#" + (ident.isEmpty ? String(index) : ident),
                appName: app.localizedName ?? bundle,
                bundleId: bundle,
                label: [title, desc].first { !$0.isEmpty } ?? "",
                minX: point.x, width: size.width,
                visibility: MenuItemVisibility.classify(minX: point.x, width: size.width, notchRight: notchRight, screenMinX: screenMinX)))
        }
        return result
    }

    private static func extrasChildren(of app: NSRunningApplication) -> [AXUIElement]? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        guard let bar = attribute(element, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let kids = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return kids
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// «com.app#3» → ("com.app", 3); «com.app#com.apple.menuextra.battery» → ("com.app", nil).
    private static func split(_ id: String) -> (String, Int?)? {
        guard let hash = id.firstIndex(of: "#") else { return nil }
        return (String(id[..<hash]), Int(id[id.index(after: hash)...]))
    }
}

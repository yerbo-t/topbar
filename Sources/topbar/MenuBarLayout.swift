import AppKit
import ApplicationServices
import CoreGraphics

/// Что сейчас лежит в строке меню встроенного экрана. Окна значков видны через список окон без особых разрешений;
/// чей значок — не узнать (на macOS 26 все они принадлежат «Пункту управления»), да это и не нужно: важны только места.
enum MenuBarLayout {
    /// Длина значка topbar в строке меню (окно значка шире на 16 пунктов отступов).
    static let controlIconLength: CGFloat = 20

    /// Рамки значков в строке меню (в координатах экрана с началом слева вверху), без окон самого острова.
    static func statusItemFrames(on screen: NSScreen) -> [CGRect] {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let display = CGDisplayBounds(id)
        let me = ProcessInfo.processInfo.processIdentifier
        var frames: [CGRect] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 25,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { continue }
            guard abs(rect.minY - display.minY) <= 1, rect.height >= 18, rect.height <= 40,
                  rect.minX >= display.minX, rect.maxX <= display.maxX + 1 else { continue }
            // Окно острова (наше, всегда накрывает центр выреза) значком не считается.
            if (window[kCGWindowOwnerPID as String] as? Int32) == me, rect.minX <= display.midX, rect.maxX >= display.midX { continue }
            frames.append(rect)
        }
        return frames
    }

    enum FreeSpace: Equatable {
        case unknown          // строка меню сейчас не видна (полноэкранное окно) — значков не разглядеть
        case unlimited        // строка видна, значков справа от выреза нет
        case points(CGFloat)  // место до первого значка
    }

    /// Свободное место справа от выреза до первого значка. Значки, лежащие в зоне выреза, не считаются: система их всё
    /// равно не показывает.
    static func freeSpaceRightOfNotch(on screen: NSScreen, notchWidth: CGFloat) -> FreeSpace {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return .unknown }
        let frames = statusItemFrames(on: screen)
        guard !frames.isEmpty else { return .unknown }
        let notchRight = CGDisplayBounds(id).midX + notchWidth / 2
        let starts = frames
            .filter { $0.maxX > notchRight + 1 && $0.width > 0 }
            .map(\.minX)
            .filter { $0 >= notchRight - 1 }
        guard let first = starts.min() else { return .unlimited }
        return .points(max(0, first - notchRight))
    }

    /// Свободное место слева от выреза: от правого края последнего меню приложения, которому сейчас принадлежит строка меню
    /// («Справка» у большинства), до выреза. Меню — не окна: их видно только через «Универсальный доступ»; без него — `.unknown`
    /// (уши ведут себя как раньше). Положение берётся относительно левого края экрана, на котором меню нарисованы: на всех
    /// экранах они лежат одинаково.
    static func freeSpaceLeftOfNotch(on screen: NSScreen, notchWidth: CGFloat) -> FreeSpace {
        guard AXIsProcessTrusted(),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let app = NSWorkspace.shared.menuBarOwningApplication else { return .unknown }
        let display = CGDisplayBounds(id)
        let notchLeft = display.midX - notchWidth / 2
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Зависшее приложение не должно подвешивать остров: ответа ждём недолго.
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard let bar = axAttribute(element, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let items = axAttribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return .unknown }
        for item in items.reversed() {
            guard let frame = axFrame(item), frame.width > 0 else { continue }
            // Экран, на котором лежит это меню (строка меню может быть на другом мониторе).
            var shown: CGDirectDisplayID = 0, count: UInt32 = 0
            let origin = CGDisplayBounds(CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &shown, &count) == .success && count > 0 ? shown : id).minX
            let maxX = display.minX + (frame.maxX - origin)
            // Меню, которые система убрала за вырез (не поместились), не считаются.
            guard display.minX + (frame.minX - origin) < notchLeft else { continue }
            return .points(max(0, notchLeft - maxX))
        }
        // У приложения со строкой меню всегда есть хотя бы меню Apple: пустой список значит «меню ещё не прочитались» (Zoom
        // сразу после перехода), а не «места вдоволь» — иначе уши на миг раздуваются во всю ширину и накрывают «Справку».
        return .unknown
    }

    private static func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == 2 else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        let pos = list[0] as CFTypeRef, dim = list[1] as CFTypeRef
        guard CFGetTypeID(pos) == AXValueGetTypeID(), AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              CFGetTypeID(dim) == AXValueGetTypeID(), AXValueGetValue(dim as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

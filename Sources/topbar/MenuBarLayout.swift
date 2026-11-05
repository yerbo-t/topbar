import AppKit
import CoreGraphics

/// Что сейчас лежит в строке меню встроенного экрана. Окна значков видны через список окон без особых разрешений;
/// чей значок — не узнать (на macOS 26 все они принадлежат «Пункту управления»), да это и не нужно: важны только места.
enum MenuBarLayout {
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
}

import AppKit

/// Встроенный экран с вырезом и размеры выреза.
struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static func find() -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
        var width: CGFloat = 200
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = screen.frame.width - left.width - right.width
        }
        return NotchGeometry(screen: screen, notchWidth: width, notchHeight: screen.safeAreaInsets.top)
    }
}

/// Потокобезопасное состояние, которое хаб читает со своей очереди (NSScreen и NSWorkspace трогать оттуда нельзя).
final class SystemState {
    private let lock = NSLock()
    private var _frontmost: String?
    private var _hasNotch = false
    private var observers: [NSObjectProtocol] = []

    init() {
        _frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        _hasNotch = NotchGeometry.find() != nil
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(frontmost: app?.bundleIdentifier)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshScreens()
        })
    }

    var frontmostBundleId: String? {
        if CommandLine.arguments.contains("--debug-not-watching") { return nil }
        lock.lock(); defer { lock.unlock() }; return _frontmost
    }
    var hasNotchScreen: Bool { lock.lock(); defer { lock.unlock() }; return _hasNotch }

    private func set(frontmost: String?) { lock.lock(); _frontmost = frontmost; lock.unlock() }

    func refreshScreens() {
        let has = NotchGeometry.find() != nil
        lock.lock(); _hasNotch = has; lock.unlock()
    }
}

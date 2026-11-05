import AppKit

/// Разрешение «Автоматизация» на управление Ghostty. Спрашиваем и проверяем не на главном потоке: окно запроса системы
/// иначе заморозило бы остров до ответа владельца. Пока доступа нет, всё работает по приложению, а не по терминалу.
final class GhosttyAccess: @unchecked Sendable {
    static let shared = GhosttyAccess()
    private let lock = NSLock()
    private var granted = false
    private var asked = false

    var isGranted: Bool { lock.lock(); defer { lock.unlock() }; return granted }

    /// Узнать состояние разрешения; `ask` — показать системный запрос (один раз за запуск).
    func refresh(ask: Bool) {
        lock.lock()
        let shouldAsk = ask && !asked
        if shouldAsk { asked = true }
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").isEmpty else { return }
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.mitchellh.ghostty")
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, shouldAsk)
            lock.lock(); granted = (status == noErr); lock.unlock()
        }
    }
}

/// Управление Ghostty через его AppleScript-словарь: какой терминал в фокусе и как перенести владельца к терминалу сессии.
/// Нужен доступ «Автоматизация» (система спросит один раз). Ghostty не запускаем: если он закрыт, не делаем ничего.
@MainActor
enum GhosttyScripting {
    static let bundleId = "com.mitchellh.ghostty"

    private static var cachedTTY: (value: String?, at: Date)?
    private static let focusedScript = NSAppleScript(source:
        "tell application \"Ghostty\" to get tty of focused terminal of selected tab of front window")

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Терминал в фокусе (`/dev/ttys004`); ответ кэшируется на полсекунды, чтобы не гонять AppleScript на каждое событие.
    static func focusedTTY() -> String? {
        guard isRunning, GhosttyAccess.shared.isGranted else { return nil }
        if let cached = cachedTTY, Date().timeIntervalSince(cached.at) < 0.5 { return cached.value }
        var error: NSDictionary?
        let value = focusedScript?.executeAndReturnError(&error).stringValue
        cachedTTY = (error == nil ? value : nil, Date())
        return cachedTTY?.value
    }

    /// Перенести в терминал с этим tty (`ttys004`): вкладка выбирается, окно выходит вперёд. false — не нашли или нет доступа.
    @discardableResult
    static func focus(tty: String) -> Bool {
        guard isRunning, GhosttyAccess.shared.isGranted else { return false }
        let device = "/dev/" + tty.replacingOccurrences(of: "\"", with: "")
        let source = """
        tell application "Ghostty"
            set matches to (every terminal whose tty is "\(device)")
            if (count of matches) > 0 then
                focus (item 1 of matches)
                return "ok"
            end if
            return "none"
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        cachedTTY = nil
        return error == nil && result == "ok"
    }
}

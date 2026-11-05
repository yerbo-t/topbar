import AppKit

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
        guard isRunning else { return nil }
        if let cached = cachedTTY, Date().timeIntervalSince(cached.at) < 0.5 { return cached.value }
        var error: NSDictionary?
        let value = focusedScript?.executeAndReturnError(&error).stringValue
        cachedTTY = (error == nil ? value : nil, Date())
        return cachedTTY?.value
    }

    /// Перенести в терминал с этим tty (`ttys004`): вкладка выбирается, окно выходит вперёд. false — не нашли или нет доступа.
    @discardableResult
    static func focus(tty: String) -> Bool {
        guard isRunning else { return false }
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

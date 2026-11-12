import AppKit
import TopbarCore

/// Разрешение «Автоматизация» на управление терминалом, по приложениям. Спрашиваем и проверяем не на главном потоке: окно
/// запроса системы иначе заморозило бы остров до ответа владельца. Пока доступа нет, всё работает по приложению, а не по
/// вкладке терминала.
final class AutomationAccess: @unchecked Sendable {
    static let shared = AutomationAccess()
    private let lock = NSLock()
    private var granted: Set<String> = []
    private var asked: Set<String> = []
    private var lastCheck: [String: Date] = [:]

    func isGranted(_ bundleId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return granted.contains(bundleId) }

    /// Узнать состояние разрешения; `ask` — показать системный запрос (один раз за запуск на приложение). Частые проверки
    /// (идут на каждое событие и раз в секунду из окна настройки) схлопываются: не чаще раза в две секунды, но первый запрос
    /// разрешения не теряется. Незапущенное приложение пропускаем: система ответить не может, и «спрашивали» не считается.
    func refresh(_ bundleId: String, ask: Bool) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { return }
        lock.lock()
        let now = Date()
        let willAsk = ask && !asked.contains(bundleId)
        if !willAsk, let last = lastCheck[bundleId], now.timeIntervalSince(last) < 2 { lock.unlock(); return }
        lastCheck[bundleId] = now
        if willAsk { asked.insert(bundleId) }
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, willAsk)
            lock.lock()
            if status == noErr { granted.insert(bundleId) } else { granted.remove(bundleId) }
            lock.unlock()
        }
    }
}

/// Управление терминалами через их AppleScript-словарь: какая вкладка в фокусе и как перенести владельца к вкладке сессии.
/// Умеют Ghostty, Terminal и iTerm2; у остальных приложение просто выходит вперёд. Нужен доступ «Автоматизация» (система
/// спросит один раз на приложение). Терминал не запускаем: если он закрыт, не делаем ничего.
@MainActor
enum TerminalScripting {
    struct Driver {
        let name: String
        /// Строка AppleScript: tty вкладки в фокусе.
        let focusedScript: String
        /// Строка AppleScript: выбрать вкладку с этим tty (`/dev/ttys004`) и вернуть "ok", если нашли.
        let focusScript: (_ device: String) -> String
        /// Строка AppleScript: закрыть вкладку (или часть окна) с этим tty и вернуть "ok"; nil — закрывать не умеем.
        var closeScript: ((_ device: String) -> String)? = nil
    }

    static let ghostty = "com.mitchellh.ghostty"

    static let drivers: [String: Driver] = [
        ghostty: Driver(
            name: "Ghostty",
            focusedScript: "tell application \"Ghostty\" to get tty of focused terminal of selected tab of front window",
            focusScript: { device in """
                tell application "Ghostty"
                    set matches to (every terminal whose tty is "\(device)")
                    if (count of matches) > 0 then
                        focus (item 1 of matches)
                        return "ok"
                    end if
                    return "none"
                end tell
                """ },
            closeScript: { device in """
                tell application "Ghostty"
                    set matches to (every terminal whose tty is "\(device)")
                    if (count of matches) > 0 then
                        close (item 1 of matches)
                        return "ok"
                    end if
                    return "none"
                end tell
                """ }),
        "com.apple.Terminal": Driver(
            name: "Terminal",
            focusedScript: "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window",
            // Вкладка без процессов — оставшаяся после выхода оболочки: она помнит прежний tty, а его уже получила новая
            // вкладка с сессией. Такие пропускаем, иначе переход приводил в мёртвую вкладку (замер 2026-11-12).
            focusScript: { device in """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(device)" and (count of (processes of t)) > 0 then
                                if miniaturized of w then set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                return "ok"
                            end if
                        end repeat
                    end repeat
                    return "none"
                end tell
                """ },
            // Каждая вкладка Terminal в словаре — отдельное окно с одной вкладкой; закрываем, только если так и есть, чтобы не
            // закрыть заодно соседние вкладки.
            closeScript: { device in """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(device)" and (count of (processes of t)) > 0 then
                                if (count of tabs of w) is not 1 then return "none"
                                close w
                                return "ok"
                            end if
                        end repeat
                    end repeat
                    return "none"
                end tell
                """ }),
        "com.googlecode.iterm2": Driver(
            name: "iTerm2",
            focusedScript: "tell application id \"com.googlecode.iterm2\" to get tty of current session of current tab of current window",
            focusScript: { device in """
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(device)" then
                                    select w
                                    select t
                                    select s
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return "none"
                end tell
                """ }),
    ]

    /// Ответ о вкладке в фокусе: значение и до какого времени ему верить (ошибку помним дольше, чтобы не мучить зависший терминал).
    private static var cachedTTY: [String: (value: String?, until: Date)] = [:]
    private static var compiled: [String: NSAppleScript] = [:]

    /// Скрипт с предельным временем ожидания: зависший терминал задерживает приложение не дольше двух секунд.
    private static func guarded(_ body: String) -> String { "with timeout of 2 seconds\n\(body)\nend timeout" }

    static func supports(_ bundleId: String?) -> Bool { bundleId.map { drivers[$0] != nil } ?? false }

    static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Вкладка в фокусе (`/dev/ttys004`); ответ кэшируется на полсекунды, чтобы не гонять AppleScript на каждое событие.
    static func focusedTTY(bundleId: String) -> String? {
        guard let driver = drivers[bundleId], isRunning(bundleId), AutomationAccess.shared.isGranted(bundleId) else { return nil }
        if let cached = cachedTTY[bundleId], Date() < cached.until { return cached.value }
        let script = compiled[bundleId] ?? NSAppleScript(source: guarded(driver.focusedScript))
        compiled[bundleId] = script
        var error: NSDictionary?
        let value = script?.executeAndReturnError(&error).stringValue
        cachedTTY[bundleId] = error == nil ? (value, Date().addingTimeInterval(0.5)) : (nil, Date().addingTimeInterval(5))
        return cachedTTY[bundleId]?.value
    }

    /// Перенести во вкладку с этим tty (`ttys004`): вкладка выбирается, окно выходит вперёд. false — не нашли или нет доступа.
    @discardableResult
    static func focus(bundleId: String, tty: String) -> Bool {
        guard let driver = drivers[bundleId] else { return false }
        return run(driver.focusScript, bundleId: bundleId, tty: tty)
    }

    /// Умеем закрыть вкладку этого терминала: есть скрипт, терминал запущен, доступ «Автоматизация» дан.
    static func canClose(_ bundleId: String) -> Bool {
        drivers[bundleId]?.closeScript != nil && isRunning(bundleId) && AutomationAccess.shared.isGranted(bundleId)
    }

    /// Закрыть вкладку с этим tty. false — не умеем, не нашли или нет доступа.
    @discardableResult
    static func close(bundleId: String, tty: String) -> Bool {
        guard let script = drivers[bundleId]?.closeScript else { return false }
        return run(script, bundleId: bundleId, tty: tty)
    }

    private static func run(_ script: (String) -> String, bundleId: String, tty: String) -> Bool {
        guard isRunning(bundleId), AutomationAccess.shared.isGranted(bundleId) else { return false }
        let device = "/dev/" + tty.filter { $0.isLetter || $0.isNumber }
        var error: NSDictionary?
        let result = NSAppleScript(source: guarded(script(device)))?.executeAndReturnError(&error).stringValue
        cachedTTY[bundleId] = nil
        return error == nil && result == "ok"
    }
}

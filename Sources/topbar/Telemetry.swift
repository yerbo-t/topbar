import AppKit
import TopbarCore

/// «Сообщить автору, что вы пользуетесь topbar». Только с согласия: при первом запуске человек видит, что именно уйдёт,
/// и может ввести имя (или не вводить). Без адреса в Info.plist (`TopbarPingURL`) — сборка для разработки — ничего не
/// спрашивается и не отправляется. Отправка молчаливая: сбой сети никому не мешает.
@MainActor
final class Telemetry {
    private enum Key {
        static let enabled = "shareUsage"
        static let id = "installId"
        static let name = "installerName"
        static let lastSentAt = "usagePingSentAt"
        static let lastVersion = "usagePingVersion"
    }

    private let defaults = UserDefaults.standard

    var endpoint: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "TopbarPingURL") as? String).flatMap(URL.init(string:))
    }
    var isAvailable: Bool { endpoint != nil }

    /// Согласие: nil — ещё не спрашивали.
    var consent: Bool? { defaults.object(forKey: Key.enabled) as? Bool }
    var isEnabled: Bool { consent == true }

    private var installId: String {
        if let id = defaults.string(forKey: Key.id) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.id)
        return id
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    private func currentPing() -> UsagePing {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let lastSent = defaults.object(forKey: Key.lastSentAt) as? Date
        return UsagePing(id: installId, name: UsagePing.cleanName(defaults.string(forKey: Key.name)), version: version, build: build,
                         macos: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", event: UsagePing.event(lastSentAt: lastSent))
    }

    /// Первый запуск: спросить. true — человек ответил (в любую сторону).
    @discardableResult
    func askConsentIfNeeded() -> Bool {
        guard isAvailable, consent == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Сообщить автору, что вы пользуетесь topbar?"
        alert.informativeText = """
            Автору приложения придёт одна короткая запись: имя (если введёте), версия topbar и macOS, случайный номер этой установки. \
            Ничего о ваших сессиях, файлах, проектах и значках не отправляется. Запись повторяется раз в сутки; \
            отключить можно в меню в любой момент.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Ваше имя (необязательно)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Сообщить")
        alert.addButton(withTitle: "Не сообщать")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        let agreed = alert.runModal() == .alertFirstButtonReturn
        defaults.set(agreed, forKey: Key.enabled)
        if agreed { defaults.set(UsagePing.cleanName(field.stringValue), forKey: Key.name) }
        if agreed { pingIfNeeded() }
        return true
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Key.enabled)
        if on { pingIfNeeded() }
    }

    /// Изменить имя (из меню).
    func askName() {
        let alert = NSAlert()
        alert.messageText = "Как вас подписать?"
        alert.informativeText = "Имя увидит только автор приложения. Можно оставить пустым."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaults.string(forKey: Key.name) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        defaults.set(UsagePing.cleanName(field.stringValue), forKey: Key.name)
        defaults.removeObject(forKey: Key.lastSentAt)   // отправить обновлённое имя
        pingIfNeeded()
    }

    /// Что именно уходит (показывается по просьбе человека).
    func showWhatIsSent() {
        let alert = NSAlert()
        alert.messageText = "Что отправляется автору"
        alert.informativeText = currentPing().jsonString() + "\n\nАдрес: \(endpoint?.absoluteString ?? "—")"
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Отправить запись, если пора (первый раз, новая версия, прошли сутки).
    func pingIfNeeded() {
        guard isEnabled, let endpoint else { return }
        let lastSent = defaults.object(forKey: Key.lastSentAt) as? Date
        guard UsagePing.shouldSend(lastSentAt: lastSent, lastVersion: defaults.string(forKey: Key.lastVersion), version: version, now: Date()) else { return }
        let ping = currentPing()
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ping)
        let defaults = self.defaults
        let version = self.version
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }   // не дошло — повторим при следующем запуске
            defaults.set(Date(), forKey: Key.lastSentAt)
            defaults.set(version, forKey: Key.lastVersion)
        }.resume()
    }
}

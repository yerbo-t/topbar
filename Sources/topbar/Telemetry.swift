import AppKit
import TopbarCore

/// Связь с автором: «я пользуюсь topbar» (только с согласия) и отзывы (только когда человек сам нажал «Отправить»).
/// Без адреса службы в Info.plist (`TopbarServerURL`, сборка для разработки) ничего не спрашивается и не отправляется.
/// IP-адрес в записи не входит, но его видит сервер при получении: окно согласия об этом говорит прямо.
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

    private var baseURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "TopbarServerURL") as? String).flatMap(URL.init(string:))
    }
    private var pingURL: URL? { baseURL?.appendingPathComponent("api/ping") }
    private var feedbackURL: URL? { baseURL?.appendingPathComponent("api/feedback") }
    var isAvailable: Bool { baseURL != nil }

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
    private var savedName: String? { UsagePing.cleanName(defaults.string(forKey: Key.name)) }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    private func currentPing() -> UsagePing {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let lastSent = defaults.object(forKey: Key.lastSentAt) as? Date
        let gigabytes = Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30)
        return UsagePing(id: installId, name: savedName, version: version, build: build,
                         macos: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", event: UsagePing.event(lastSentAt: lastSent),
                         model: Self.sysctlString("hw.model"), chip: Self.sysctlString("machdep.cpu.brand_string"),
                         ramGB: gigabytes, language: Locale.preferredLanguages.first ?? "")
    }

    // MARK: согласие

    /// Первый запуск: спросить. true — человек ответил (в любую сторону).
    @discardableResult
    func askConsentIfNeeded() -> Bool {
        guard isAvailable, consent == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Сообщить автору, что вы пользуетесь topbar?"
        alert.informativeText = """
            Автору придёт короткая запись: имя (если введёте), модель Mac и процессор, объём памяти, версии macOS и topbar, \
            язык системы и случайный номер этой установки. Сервер при этом видит ваш IP-адрес и время. \
            Это нужно, чтобы понимать, у кого и как работает приложение, и отвечать на отзывы.

            Ничего о ваших сессиях, файлах, проектах и значках не отправляется. Запись повторяется раз в сутки и после обновления; \
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
        alert.informativeText = currentPing().jsonString() + "\n\nАдрес: \(baseURL?.absoluteString ?? "—")\nСервер дополнительно видит ваш IP-адрес и время."
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: запись «пользуюсь»

    /// Отправить запись, если пора (первый раз, новая версия, прошли сутки).
    func pingIfNeeded() {
        guard isEnabled, let url = pingURL else { return }
        let lastSent = defaults.object(forKey: Key.lastSentAt) as? Date
        guard UsagePing.shouldSend(lastSentAt: lastSent, lastVersion: defaults.string(forKey: Key.lastVersion), version: version, now: Date()) else { return }
        let ping = currentPing()
        var request = URLRequest(url: url, timeoutInterval: 8)
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

    // MARK: отзыв

    /// Окно отзыва: текст и, по желанию, как ответить. Отправляется только кнопкой «Отправить».
    func askFeedback() {
        guard feedbackURL != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Отзыв о topbar"
        alert.informativeText = "Что работает, что мешает, чего не хватает. Вместе с текстом уйдут версия приложения и номер установки; сервер видит ваш IP-адрес."
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let contact = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        contact.placeholderString = "Как вам ответить: почта или телеграм (необязательно)"
        let stack = NSStackView(views: [scroll, contact])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 152)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Отправить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let message = Feedback.cleanMessage(textView.string) else { return }
        let feedback = Feedback(id: installId, name: savedName, contact: Feedback.cleanContact(contact.stringValue),
                                message: message, version: version, build: build)
        Task { await send(feedback) }
    }

    private func send(_ feedback: Feedback) async {
        guard let url = feedbackURL else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(feedback)
        var delivered = false
        if let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse {
            delivered = (200..<300).contains(http.statusCode)
        }
        let alert = NSAlert()
        alert.messageText = delivered ? "Спасибо, отзыв отправлен" : "Не удалось отправить отзыв"
        alert.informativeText = delivered ? "" : "Проверьте интернет и попробуйте позже."
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

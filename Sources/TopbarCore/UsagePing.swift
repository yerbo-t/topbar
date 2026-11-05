import Foundation

/// Сообщение автору «я пользуюсь topbar» — только если владелец копии согласился. Ничего о сессиях, файлах и значках.
/// IP-адрес в сообщение не входит: его видит сам сервер при получении (окно согласия об этом предупреждает).
public struct UsagePing: Codable, Equatable, Sendable {
    public var id: String        // случайный номер установки
    public var name: String?     // имя, которое человек ввёл сам
    public var version: String
    public var build: String
    public var macos: String
    public var event: String     // "install" — первое сообщение, "launch" — последующие
    public var model: String     // модель Mac, например "Mac15,6"
    public var chip: String      // процессор, например "Apple M3 Pro"
    public var ramGB: Int
    public var language: String  // язык системы, например "ru-KZ"

    public init(id: String, name: String?, version: String, build: String, macos: String, event: String,
                model: String = "", chip: String = "", ramGB: Int = 0, language: String = "") {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.macos = macos
        self.event = event
        self.model = model
        self.chip = chip
        self.ramGB = ramGB
        self.language = language
    }

    /// Имя для отправки: обрезано и без лишних пробелов; пустое — не отправляется.
    public static func cleanName(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }

    /// Слать при первом запуске, при смене версии и не чаще раза в сутки.
    public static func shouldSend(lastSentAt: Date?, lastVersion: String?, version: String, now: Date) -> Bool {
        guard let lastSentAt else { return true }
        if lastVersion != version { return true }
        return now.timeIntervalSince(lastSentAt) >= 24 * 3600
    }

    public static func event(lastSentAt: Date?) -> String { lastSentAt == nil ? "install" : "launch" }

    /// Ровно то, что уйдёт на сервер (показывается человеку по его просьбе).
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
    }
}

/// Отзыв, который человек сам написал в приложении и отправил кнопкой.
public struct Feedback: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var contact: String?   // как ответить: почта, телеграм — по желанию
    public var message: String
    public var version: String
    public var build: String

    public init(id: String, name: String?, contact: String?, message: String, version: String, build: String) {
        self.id = id
        self.name = name
        self.contact = contact
        self.message = message
        self.version = version
        self.build = build
    }

    public static let maxLength = 4000

    /// Текст отзыва: без пустых краёв, не длиннее предела; пустой — nil (отправлять нечего).
    public static func cleanMessage(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxLength))
    }

    public static func cleanContact(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(100))
    }
}

import Foundation

/// Сообщение автору «я пользуюсь topbar» — только если владелец копии согласился. Ничего о сессиях, файлах и значках.
public struct UsagePing: Codable, Equatable, Sendable {
    public var id: String        // случайный номер установки
    public var name: String?     // имя, которое человек ввёл сам
    public var version: String
    public var build: String
    public var macos: String
    public var event: String     // "install" — первое сообщение, "launch" — последующие

    public init(id: String, name: String?, version: String, build: String, macos: String, event: String) {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.macos = macos
        self.event = event
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

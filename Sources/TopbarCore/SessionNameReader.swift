import Foundation

/// Имя сессии из её журнала (`transcript_path`): заданное владельцем через `/rename` (`custom-title`), а если его нет —
/// придуманное Claude Code (`ai-title`). Из журнала разбираются только эти строки, остальное содержимое не читается в память
/// как данные и никуда не уходит.
///
/// Журналы бывают в десятки мегабайт, но Claude Code дописывает имя заново почти на каждом шаге, поэтому в первый раз
/// читается только хвост файла, а дальше — только дописанное с прошлого раза.
public final class SessionNameReader: @unchecked Sendable {
    public static let defaultTailLimit = 4 << 20

    private struct Entry {
        var offset: UInt64 = 0
        var custom: String?
        var ai: String?
        var name: String? { custom ?? ai }
    }

    private let tailLimit: Int
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]

    public init(tailLimit: Int = SessionNameReader.defaultTailLimit) {
        self.tailLimit = tailLimit
    }

    public func name(at path: String) -> String? {
        guard path.hasSuffix(".jsonl") else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            cache[path] = nil
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return cache[path]?.name }
        var entry = cache[path] ?? Entry()
        if size < entry.offset { entry = Entry() }   // журнал переписан заново
        guard size > entry.offset else { return entry.name }

        let start = max(entry.offset, size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0)
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else { return entry.name }

        // Последняя строка может быть ещё недописана: её дочитаем в следующий раз.
        let complete: Data
        if let lastNewline = data.lastIndex(of: 0x0A) {
            complete = data[data.startIndex...lastNewline]
            entry.offset = start + UInt64(complete.count)
        } else {
            complete = Data()
            entry.offset = start
        }
        for line in complete.split(separator: 0x0A) {
            if line.range(of: Self.customMarker) != nil, let title = Self.value(line, key: "customTitle") {
                entry.custom = title.isEmpty ? nil : title
            } else if line.range(of: Self.aiMarker) != nil, let title = Self.value(line, key: "aiTitle"), !title.isEmpty {
                entry.ai = title
            }
        }
        cache[path] = entry
        return entry.name
    }

    // Именно так строка выглядит в журнале; внутри текста сообщений кавычки экранированы, и маркер там не совпадёт.
    private static let customMarker = Data("\"type\":\"custom-title\"".utf8)
    private static let aiMarker = Data("\"type\":\"ai-title\"".utf8)

    private static func value(_ line: Data, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, type == "custom-title" || type == "ai-title",
              let raw = object[key] as? String else { return nil }
        let text = ActionDescriber.oneLine(raw.trimmingCharacters(in: .whitespacesAndNewlines), limit: 120)
        return text
    }
}

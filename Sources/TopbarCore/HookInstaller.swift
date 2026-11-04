import Foundation

/// Вписывает и убирает хуки topbar в settings.json Claude Code. Записи узнаются по метке в команде.
public enum HookInstaller {
    public static let marker = "# topbar-managed"

    /// Какие события слушаем и сколько секунд Claude Code ждёт хук.
    public static let events: [(name: String, timeout: Int)] = [
        ("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5),
        ("PermissionRequest", 600), ("PostToolUse", 5), ("PostToolUseFailure", 5),
        ("Stop", 5), ("StopFailure", 5), ("SessionEnd", 5),
    ]

    public enum InstallError: Error, Equatable {
        case notAnObject
        /// Значение хуков события имеет неожиданный вид; файл не трогаем, чтобы не затереть чужое.
        case unexpectedShape(String)
    }

    public static func command(bridgePath: String) -> String {
        let quoted = "'" + bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(marker)"
    }

    public static func install(into data: Data?, bridgePath: String) throws -> Data {
        var root = try parse(data)
        var hooks = try hooksObject(root)
        for (name, timeout) in events {
            var groups = try groups(hooks, name).compactMap(strippingManaged)
            groups.append(["hooks": [["type": "command", "command": command(bridgePath: bridgePath), "timeout": timeout]]])
            hooks[name] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func remove(from data: Data) throws -> Data {
        var root = try parse(data)
        guard var hooks = try hooksObjectIfAny(root) else { return try serialize(root) }
        for name in Array(hooks.keys) {
            let remaining = try groups(hooks, name).compactMap(strippingManaged)
            hooks[name] = remaining.isEmpty ? nil : remaining
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    public static func isInstalled(in data: Data?) -> Bool {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains(where: containsManaged)
        }
    }

    /// Пути моста, на которые ссылаются хуки topbar (для проверки, что файл ещё существует).
    public static func bridgePaths(in data: Data?) -> Set<String> {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return [] }
        var result = Set<String>()
        for value in hooks.values {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] where isManaged(hook) {
                    if let command = hook["command"] as? String, let path = unquotedPath(command) { result.insert(path) }
                }
            }
        }
        return result
    }

    /// Построчная разница «как в файле сейчас → как будет записано».
    public static func diff(old: Data?, new: Data) -> String {
        let oldLines = old.map(lines) ?? []
        var out: [String] = []
        for change in lines(new).difference(from: oldLines) {
            switch change {
            case .insert(_, let line, _): out.append("+ " + line)
            case .remove(_, let line, _): out.append("- " + line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Запись пересоберёт файл (отсортирует ключи, изменит отступы), даже если хуки не менялись.
    public static func willReformat(_ old: Data?) -> Bool {
        guard let old, !old.isEmpty, let root = try? parse(old), let normal = try? serialize(root) else { return false }
        return normal != old
    }

    // MARK: внутреннее

    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.notAnObject
        }
        return obj
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func hooksObjectIfAny(_ root: [String: Any]) throws -> [String: Any]? {
        guard let value = root["hooks"] else { return nil }
        guard let hooks = value as? [String: Any] else { throw InstallError.unexpectedShape("hooks") }
        return hooks
    }

    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        try hooksObjectIfAny(root) ?? [:]
    }

    private static func groups(_ hooks: [String: Any], _ name: String) throws -> [[String: Any]] {
        guard let value = hooks[name] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw InstallError.unexpectedShape(name) }
        return groups
    }

    private static func isManaged(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) ?? false
    }

    private static func containsManaged(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains(where: isManaged)
    }

    /// Группа без наших хуков; пустая группа пропадает (nil).
    private static func strippingManaged(_ group: [String: Any]) -> [String: Any]? {
        var group = group
        let rest = (group["hooks"] as? [[String: Any]] ?? []).filter { !isManaged($0) }
        if rest.isEmpty { return nil }
        group["hooks"] = rest
        return group
    }

    /// Путь из команды вида `'/путь с пробелами/topbar-hook' # topbar-managed`.
    private static func unquotedPath(_ command: String) -> String? {
        guard command.hasPrefix("'"), let end = command.range(of: "' ", range: command.index(after: command.startIndex)..<command.endIndex)
        else { return nil }
        let inner = command[command.index(after: command.startIndex)..<end.lowerBound]
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }
}

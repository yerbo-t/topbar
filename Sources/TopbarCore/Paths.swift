import Foundation

public enum Paths {
    public static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/topbar" }
    /// Только для отладки приложения (`--socket <путь>`): другой сокет, чтобы не мешать установленному экземпляру.
    nonisolated(unsafe) public static var socketPathOverride: String?
    public static var socketPath: String { socketPathOverride ?? supportDir + "/hook.sock" }
    /// Стабильный путь моста: хуки в настройках Claude Code ссылаются именно на него.
    public static var bridgeInstallPath: String { supportDir + "/bin/topbar-hook" }
}

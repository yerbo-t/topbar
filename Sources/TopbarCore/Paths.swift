import Foundation

public enum Paths {
    public static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/topbar" }
    public static var socketPath: String { supportDir + "/hook.sock" }
    /// Стабильный путь моста: хуки в настройках Claude Code ссылаются именно на него.
    public static var bridgeInstallPath: String { supportDir + "/bin/topbar-hook" }
}

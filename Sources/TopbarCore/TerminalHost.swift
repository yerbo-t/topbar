import Foundation

/// Приложения, в которых запускают Claude Code (терминалы и редакторы): как их назвать и по какому идентификатору вывести
/// на передний план. Неизвестное приложение не теряется: идентификатор хранится у сессии, а имя ему даёт слой с окнами.
public enum TerminalHost {
    public struct App: Equatable, Sendable {
        public let name: String
        public let bundleId: String
        /// Значение `TERM_PROGRAM`, которое это приложение выставляет (если выставляет).
        public let termProgram: String?
        /// Редактор в духе VS Code: переходим к сессии, открывая папку проекта.
        public let isEditor: Bool

        init(_ name: String, _ bundleId: String, term: String? = nil, editor: Bool = false) {
            self.name = name
            self.bundleId = bundleId
            self.termProgram = term
            self.isEditor = editor
        }
    }

    public static let apps: [App] = [
        App("Ghostty", "com.mitchellh.ghostty", term: "ghostty"),
        App("Terminal", "com.apple.Terminal", term: "Apple_Terminal"),
        App("iTerm2", "com.googlecode.iterm2", term: "iTerm.app"),
        App("Warp", "dev.warp.Warp-Stable", term: "WarpTerminal"),
        App("Warp", "dev.warp.Warp-Preview"),
        App("WezTerm", "com.github.wez.wezterm", term: "WezTerm"),
        App("kitty", "net.kovidgoyal.kitty"),
        App("Alacritty", "org.alacritty"),
        App("Hyper", "co.zeit.hyper", term: "Hyper"),
        App("Tabby", "org.tabby", term: "Tabby"),
        App("Rio", "com.raphaelamorim.rio", term: "rio"),
        App("VS Code", "com.microsoft.VSCode", term: "vscode", editor: true),
        App("VS Code Insiders", "com.microsoft.VSCodeInsiders", editor: true),
        App("VSCodium", "com.vscodium", editor: true),
        App("Cursor", "com.todesktop.230313mzl4w4u92", editor: true),
        App("Windsurf", "com.exafunction.windsurf", editor: true),
    ]

    static func app(bundleId: String) -> App? { apps.first { $0.bundleId == bundleId } }
    static func app(termProgram: String) -> App? { apps.first { $0.termProgram == termProgram } }

    /// Название для списка. Сообщённое приложение важнее `TERM_PROGRAM` (форки VS Code и tmux выставляют чужое значение);
    /// неизвестное приложение — nil, пусть имя подберёт слой с окнами. Без приложения — по `TERM_PROGRAM`, а незнакомое
    /// его значение (`tmux`) остаётся как есть.
    public static func name(termProgram: String?, bundleId: String?) -> String? {
        if let bundleId { return app(bundleId: bundleId)?.name }
        guard let termProgram else { return nil }
        return app(termProgram: termProgram)?.name ?? termProgram
    }

    /// Приложение, которое надо вывести вперёд: сообщённое, а если его нет — по `TERM_PROGRAM`.
    public static func bundleId(termProgram: String?, bundleId: String?) -> String? {
        if let bundleId { return bundleId }
        return termProgram.flatMap { app(termProgram: $0)?.bundleId }
    }

    /// Для сессий, у которых есть только прежнее имя хоста.
    public static func bundleId(forName name: String?) -> String? {
        name.flatMap { name in apps.first { $0.name == name }?.bundleId }
    }

    public static func isEditor(bundleId: String?) -> Bool {
        bundleId.flatMap { app(bundleId: $0)?.isEditor } ?? false
    }
}

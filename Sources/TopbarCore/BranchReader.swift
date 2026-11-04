import Foundation

public enum BranchReader {
    /// Имя ветки по `.git/HEAD` (выше по дереву от `dir`). Worktree (`.git` — файл) поддержан.
    /// Detached HEAD, каталог без git → nil.
    public static func branch(at dir: String) -> String? {
        var current = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        for _ in 0..<12 {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let headDir: URL
                if isDir.boolValue {
                    headDir = dotGit
                } else if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          text.hasPrefix("gitdir:") {
                    let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    headDir = URL(fileURLWithPath: path, relativeTo: current)
                } else {
                    return nil
                }
                guard let head = try? String(contentsOf: headDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
                    return nil
                }
                let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }
}

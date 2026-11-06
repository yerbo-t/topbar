import Foundation

/// Подпись сессии: крупно — имя сессии (или проект, если имени нет), мелко — проект и ветка.
public struct SessionLabel: Equatable, Sendable {
    /// Крупная строка: имя сессии или проект; одинаковые различаются суффиксом « #2».
    public var title: String
    /// Проект, если крупно стоит имя сессии; nil — крупно уже проект.
    public var project: String?
    public var branch: String?

    public init(title: String, project: String?, branch: String?) {
        self.title = title
        self.project = project
        self.branch = branch
    }

    /// Мелкая строка под крупной: «проект · ветка» (или только ветка).
    public var context: [String] { [project, branch].compactMap { $0 } }
}

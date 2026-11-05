import Foundation

enum Settings {
    private static let soundKey = "soundEnabled"
    private static let hiderKey = "hidesMenuBarIcons"
    private static let hiderHintKey = "menuBarHintShown"

    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }

    /// Кнопка сворачивания значков строки меню включена.
    static var hidesMenuBarIcons: Bool {
        get { UserDefaults.standard.object(forKey: hiderKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hiderKey) }
    }

    /// Подсказка «как настроить» уже показывалась сама.
    static var menuBarHintShown: Bool {
        get { UserDefaults.standard.bool(forKey: hiderHintKey) }
        set { UserDefaults.standard.set(newValue, forKey: hiderHintKey) }
    }
}

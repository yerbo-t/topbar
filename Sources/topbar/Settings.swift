import Foundation

enum Settings {
    private static let soundKey = "soundEnabled"
    private static let hiderKey = "hidesMenuBarIcons"
    private static let playerKey = "playerEnabled"
    private static let setupGuideKey = "setupGuideShown"

    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }

    /// Кнопка сворачивания значков строки меню включена.
    static var hidesMenuBarIcons: Bool {
        get { UserDefaults.standard.object(forKey: hiderKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hiderKey) }
    }

    /// Окно «Настройка и подсказки» уже показывалось само (при первом запуске).
    static var setupGuideShown: Bool {
        get { UserDefaults.standard.bool(forKey: setupGuideKey) }
        set { UserDefaults.standard.set(newValue, forKey: setupGuideKey) }
    }

    /// Плеер («Сейчас играет») показывается на острове.
    static var playerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: playerKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: playerKey) }
    }
}

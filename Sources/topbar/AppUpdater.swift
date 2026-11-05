import AppKit
import Sparkle
import UserNotifications

/// Обновления (Sparkle) без принуждения. Раз в несколько часов приложение смотрит ленту; найдя новую версию, ничего не скачивает
/// и не ставит: показывает уведомление, строку «Обновить до …» в меню и крупную кнопку в списке значков. Кнопка открывает окно
/// Sparkle с описанием версии: «Установить» скачивает, проверяет подпись (EdDSA) и перезапускает приложение. Версия в ленте всегда
/// одна, последняя. Без адреса ленты в Info.plist (сборка для разработки) обновлений нет.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    private var controller: SPUStandardUpdaterController?
    private let defaults = UserDefaults.standard
    private static let notifiedKey = "updateNotifiedVersion"

    /// Версия, о которой знаем, но не поставили; nil — новой нет.
    private(set) var availableVersion: String? {
        didSet { if oldValue != availableVersion { onAvailabilityChange?(availableVersion) } }
    }
    var onAvailabilityChange: ((String?) -> Void)?

    var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String }

    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Открыть окно Sparkle: если новая версия есть — описание и «Установить»; если нет — «У вас последняя версия».
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate — мягкие напоминания

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Плановую проверку окном не показываем: даём знать сами, не отнимая фокус у работы.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        availableVersion = update.displayVersionString
        notifyOnce(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { removeDeliveredNotification() }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        removeDeliveredNotification()
    }

    // MARK: уведомление

    private func notifyOnce(version: String) {
        guard defaults.string(forKey: Self.notifiedKey) != version else { return }
        defaults.set(version, forKey: Self.notifiedKey)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Вышла новая версия topbar"
            content.body = "Версия \(version). Нажмите, чтобы посмотреть, что нового, и обновить."
            center.add(UNNotificationRequest(identifier: "topbar-update", content: content, trigger: nil))
        }
    }

    private func removeDeliveredNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["topbar-update"])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.checkForUpdates() } }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

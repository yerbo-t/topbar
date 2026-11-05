import AppKit
import Sparkle

/// Автообновление (Sparkle): раз в несколько часов приложение смотрит ленту обновлений, сама скачивает и проверяет подпись
/// (EdDSA) и ставит обновление, когда это никому не мешает: нет открытых запросов разрешений. Без адреса ленты в Info.plist
/// (сборка для разработки) обновления выключены.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?

    /// Можно ли сейчас перезапустить приложение для обновления (ставит AppDelegate).
    var canRestartNow: () -> Bool = { true }

    var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String }

    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Проверка по просьбе владельца (с окном Sparkle: «есть новая версия» или «у вас последняя»).
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    /// Обновление скачано и проверено, Sparkle поставил бы его при выходе. Мы ставим сами, когда можно перезапуститься.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.install(when: immediateInstallHandler) } }
        return true
    }

    // MARK: внутреннее

    private func install(when block: @escaping () -> Void) {
        pendingInstall = block
        tryInstall()
        guard pendingInstall != nil, idleTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryInstall() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func tryInstall() {
        guard let block = pendingInstall, canRestartNow() else { return }
        pendingInstall = nil
        idleTimer?.invalidate()
        idleTimer = nil
        block()
    }
}

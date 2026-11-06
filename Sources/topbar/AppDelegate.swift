import AppKit
import TopbarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hub: SessionHub!
    private var model: IslandViewModel!
    private var panel: IslandPanelController!
    private var menu: MenuController!
    private let system = SystemState()
    private let updater = AppUpdater()
    private let telemetry = Telemetry()
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--socket"), i + 1 < CommandLine.arguments.count {
            Paths.socketPathOverride = CommandLine.arguments[i + 1]
        }
        BridgeSync.syncIfNeeded()
        hub = SessionHub(socketPath: Paths.socketPath, callbackQueue: .main)
        model = IslandViewModel(hub: hub, system: system)
        panel = IslandPanelController(model: model)
        menu = MenuController()
        menu.onPlayerToggle = { [weak self] on in self?.model.setPlayerEnabled(on) }
        menu.updater = updater
        menu.telemetry = telemetry

        do { try hub.start() } catch SocketError.alreadyRunning {
            fatal("topbar уже запущен", "Сокет \(Paths.socketPath) слушает другой экземпляр.")
            return
        } catch {
            fatal("Не удалось запуститься", "Сокет \(Paths.socketPath): \(error)")
            return
        }

        model.startPlayerIfEnabled()
        if !CommandLine.arguments.contains("--skip-onboarding") || CommandLine.arguments.contains("--debug-updater") { updater.start() }
        if CommandLine.arguments.contains("--debug-ping") { telemetry.pingIfNeeded() }
        if CommandLine.arguments.contains("--debug-feedback") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.telemetry.askFeedback() }
        }
        // Точное определение вкладки в Ghostty (Terminal и iTerm2 спросим, когда владелец окажется в них с сессией): узнать (и при необходимости спросить) разрешение «Автоматизация».
        if !CommandLine.arguments.contains("--skip-onboarding") { AutomationAccess.shared.refresh(TerminalScripting.ghostty, ask: true) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.system.refreshScreens()
                if !self.system.hasNotchScreen { self.model.releaseCards() }
                self.panel.layout()
            }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == TerminalScripting.ghostty { AutomationAccess.shared.refresh(TerminalScripting.ghostty, ask: true) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.releaseCards() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hub.tickNow(); self?.panel.layout() }
        })

        // Первый запуск: спросить согласие на сообщение автору, затем — если хуков ещё нет — предложить поставить.
        DispatchQueue.main.async { [weak self] in
            guard let self, !CommandLine.arguments.contains("--skip-onboarding") else { return }
            self.telemetry.askConsentIfNeeded()
            self.telemetry.pingIfNeeded()
            guard !HooksController().isInstalledAndHealthy() else { return }
            let alert = NSAlert()
            alert.messageText = "Подключить Claude Code?"
            alert.informativeText = "Чтобы остров видел сессии, нужно вписать хуки в настройки Claude Code. Перед записью вы увидите точную разницу."
            alert.addButton(withTitle: "Показать изменения")
            alert.addButton(withTitle: "Позже")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { self.menu.installHooks() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { hub?.stop(); model?.player.stop() }

    private func fatal(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
        NSApp.terminate(nil)
    }
}

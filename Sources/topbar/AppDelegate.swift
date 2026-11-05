import AppKit
import TopbarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hub: SessionHub!
    private var model: IslandViewModel!
    private var panel: IslandPanelController!
    private var menu: MenuController!
    private let system = SystemState()
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

        do { try hub.start() } catch SocketError.alreadyRunning {
            fatal("topbar уже запущен", "Сокет \(Paths.socketPath) слушает другой экземпляр.")
            return
        } catch {
            fatal("Не удалось запуститься", "Сокет \(Paths.socketPath): \(error)")
            return
        }

        model.startPlayerIfEnabled()
        // Точное определение терминала в Ghostty: узнать (и при необходимости спросить) разрешение «Автоматизация».
        if !CommandLine.arguments.contains("--skip-onboarding") { GhosttyAccess.shared.refresh(ask: true) }
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
            if app?.bundleIdentifier == GhosttyScripting.bundleId { GhosttyAccess.shared.refresh(ask: true) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.releaseCards() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hub.tickNow(); self?.panel.layout() }
        })

        // Первый запуск: хуков ещё нет — предложить поставить.
        DispatchQueue.main.async { [weak self] in
            guard let self, !CommandLine.arguments.contains("--skip-onboarding"), !HooksController().isInstalledAndHealthy() else { return }
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

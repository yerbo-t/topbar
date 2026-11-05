import AppKit
import ServiceManagement
import TopbarCore

/// Иконка в строке меню: вход в управление приложением. Пока включено сворачивание значков, левый клик по ней прячет и
/// показывает значки других приложений, а меню открывается правым кликом (или клик с Control).
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let hooks = HooksController()
    private let hider = MenuBarHider()
    private let list = MenuBarListController()
    /// Владелец включил или выключил плеер в меню.
    var onPlayerToggle: ((Bool) -> Void)?
    /// Обновления (nil — не настроены в этой сборке).
    var updater: AppUpdater?
    /// Сообщение автору об использовании (nil или недоступно — в этой сборке не используется).
    var telemetry: Telemetry?

    override init() {
        if Settings.hidesMenuBarIcons { MenuBarHider.seedPositions() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = MenuBarHider.controlName
        super.init()
        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        list.model.onNeedsSetup = { [weak self] in self?.list.hide(); self?.showSetupHint() }
        hider.onStateChange = { [weak self] in self?.updateIcon(); self?.list.model.objectWillChange.send() }
        hider.onSafetyRevert = { [weak self] in self?.showSafetyAlert() }
        if Settings.hidesMenuBarIcons { hider.enable(control: statusItem); list.model.hider = hider }
        updateIcon()
        if CommandLine.arguments.contains("--debug-hider-selftest") { hider.selfTest() }
        if CommandLine.arguments.contains("--debug-open-icon-list") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let frame = self.statusItem.button?.window?.frame else { return }
                self.list.show(anchoredTo: frame)
            }
        }
    }

    // MARK: значок и клики

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        if !hider.isEnabled {
            name = "capsule.portrait.tophalf.filled"
            button.toolTip = "Значки строки меню (правый клик — меню topbar)"
        } else if hider.isCollapsed {
            name = "chevron.left"
            button.toolTip = "Значки строки меню (правый клик — меню topbar)"
        } else {
            name = "chevron.right"
            button.toolTip = "Значки строки меню (правый клик — меню topbar)"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.image = (NSImage(systemSymbolName: name, accessibilityDescription: "topbar")
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "topbar"))?.withSymbolConfiguration(config)
        button.image?.isTemplate = true
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            list.hide()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil      // иначе левый клик снова открывал бы меню
            return
        }
        guard let frame = statusItem.button?.window?.frame else { return }
        list.toggle(anchoredTo: frame)
    }

    private func showSetupHint() {
        let alert = NSAlert()
        alert.messageText = "Расставьте значки один раз"
        alert.informativeText = """
            Всё, что стоит левее черты «│», прячется кнопкой «Спрятать значки» в списке (левый клик по значку «›»). \
            Сейчас черта стоит у самого правого края, поэтому левее неё все значки.

            Зажмите ⌘ и перетащите черту «│» влево — так, чтобы слева от неё остались только те значки, которые хотите прятать. \
            Спрятанное закрывается само через \(Int(MenuBarHider.autoCollapseDelay)) с после показа.

            Меню приложения — правый клик по «›».
            """
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showSafetyAlert() {
        let alert = NSAlert()
        alert.messageText = "Значки возвращены на место"
        alert.informativeText = "Значок «›» оказался левее черты «│» и спрятался бы вместе с остальными. Перетащите его с зажатым ⌘ правее черты."
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        GhosttyAccess.shared.refresh(ask: false)
        menu.removeAllItems()
        let status = NSMenuItem(title: "Хуки Claude Code: \(hooks.statusText())", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item("Установить хуки…", #selector(installHooks)))
        menu.addItem(item("Удалить хуки…", #selector(removeHooks)))
        let ghostty = NSMenuItem(title: GhosttyAccess.shared.isGranted
            ? "Ghostty: точный терминал определяется"
            : "Ghostty: определяю по приложению (нет доступа «Автоматизация»)", action: nil, keyEquivalent: "")
        ghostty.isEnabled = false
        menu.addItem(ghostty)
        menu.addItem(.separator())
        let hiding = item("Сворачивать значки меню", #selector(toggleHiding))
        hiding.state = hider.isEnabled ? .on : .off
        menu.addItem(hiding)
        if hider.isEnabled { menu.addItem(item("Как настроить сворачивание…", #selector(setupHint))) }
        menu.addItem(.separator())
        let login = item("Запускать при входе", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let player = item("Плеер на острове", #selector(togglePlayer))
        player.state = Settings.playerEnabled ? .on : .off
        menu.addItem(player)
        let sound = item("Звук", #selector(toggleSound))
        sound.state = Settings.soundEnabled ? .on : .off
        menu.addItem(sound)
        menu.addItem(.separator())
        if let telemetry, telemetry.isAvailable {
            let share = item("Сообщать автору об использовании", #selector(toggleShare))
            share.state = telemetry.isEnabled ? .on : .off
            menu.addItem(share)
            if telemetry.isEnabled {
                menu.addItem(item("Изменить имя…", #selector(changeName)))
                menu.addItem(item("Что отправляется…", #selector(showWhatIsSent)))
            }
            menu.addItem(.separator())
        }
        if let updater {
            let version = NSMenuItem(title: "topbar \(updater.versionText)", action: nil, keyEquivalent: "")
            version.isEnabled = false
            menu.addItem(version)
            if updater.isConfigured { menu.addItem(item("Проверить обновления…", #selector(checkForUpdates))) }
        }
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc func installHooks() { hooks.install() }
    @objc func removeHooks() { hooks.remove() }
    @objc func toggleSound() { Settings.soundEnabled.toggle() }
    @objc func togglePlayer() { onPlayerToggle?(!Settings.playerEnabled) }
    @objc func setupHint() { showSetupHint() }
    @objc func checkForUpdates() { updater?.checkForUpdates() }
    @objc func toggleShare() { guard let t = telemetry else { return }; t.setEnabled(!t.isEnabled) }
    @objc func changeName() { telemetry?.askName() }
    @objc func showWhatIsSent() { telemetry?.showWhatIsSent() }

    @objc func toggleHiding() {
        Settings.hidesMenuBarIcons.toggle()
        if Settings.hidesMenuBarIcons { hider.enable(control: statusItem); list.model.hider = hider } else { hider.disable(); list.model.hider = nil }
        updateIcon()
    }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = "\(error.localizedDescription)\nПриложение должно лежать в «Программах» или «Программах» пользователя."
            alert.runModal()
        }
    }
}

/// Установка и удаление хуков в ~/.claude/settings.json с показом точной разницы.
@MainActor
final class HooksController {
    private let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

    private var bundledBridge: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("topbar-hook")
    }

    func statusText() -> String {
        let data = SettingsFile.read(settingsPath)
        guard HookInstaller.isInstalled(in: data) else { return "не установлены" }
        let missing = HookInstaller.bridgePaths(in: data).contains { !FileManager.default.isExecutableFile(atPath: $0) }
        return missing ? "установлены, но моста нет по пути" : "установлены"
    }

    func isInstalledAndHealthy() -> Bool { statusText() == "установлены" }

    func install() {
        guard let bridge = bundledBridge, FileManager.default.isExecutableFile(atPath: bridge.path) else {
            return alert("Не найден мост хука", "Файл topbar-hook должен лежать рядом с приложением.")
        }
        let old = SettingsFile.read(settingsPath)
        let new: Data
        do { new = try HookInstaller.install(into: old, bridgePath: Paths.bridgeInstallPath) } catch {
            return alert("Не удалось подготовить хуки", "Файл настроек имеет неожиданный вид (\(error)). Ничего не изменено.")
        }
        var text = HookInstaller.diff(old: old, new: new)
        if HookInstaller.willReformat(old) {
            text = "ВНИМАНИЕ: файл будет переформатирован — ключи отсортируются, отступы станут единообразными.\n\n" + text
        }
        guard confirm(title: "Вписать хуки в \(settingsPath)?", details: text, button: "Вписать хуки") else { return }
        do {
            try copyBridge(from: bridge)
            try FileManager.default.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try SettingsFile.write(new, to: settingsPath)
        } catch {
            alert("Не удалось записать хуки", error.localizedDescription)
        }
    }

    func remove() {
        guard let old = SettingsFile.read(settingsPath), HookInstaller.isInstalled(in: old) else {
            return alert("Хуков topbar нет", "В настройках Claude Code нечего убирать.")
        }
        do {
            let new = try HookInstaller.remove(from: old)
            var text = HookInstaller.diff(old: old, new: new)
            if HookInstaller.willReformat(old) { text = "ВНИМАНИЕ: файл будет переформатирован.\n\n" + text }
            guard confirm(title: "Убрать хуки topbar из \(settingsPath)?", details: text, button: "Убрать хуки") else { return }
            try SettingsFile.write(new, to: settingsPath)
        } catch {
            alert("Не удалось убрать хуки", error.localizedDescription)
        }
    }

    private func copyBridge(from source: URL) throws {
        let target = Paths.bridgeInstallPath
        let fm = FileManager.default
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.copyItem(atPath: source.path, toPath: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
    }

    private func confirm(title: String, details: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Изменения в файле (+ добавится, − уберётся):"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = details
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

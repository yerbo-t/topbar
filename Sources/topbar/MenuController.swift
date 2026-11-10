import AppKit
import ServiceManagement
import TopbarCore

/// Значок приложения в строке меню: вход в управление. Левый клик прячет значки (всё левее знака topbar) и возвращает их
/// обратно, правый клик (или клик с Control) открывает настройку значков: закрепить, скрыть, нажать; меню приложения — кнопка
/// «Меню» внизу этой панели.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let hooks = HooksController()
    private lazy var guide: SetupGuideController = {
        let guide = SetupGuideController(hooks: hooks)
        guide.model.onInstallHooks = { [weak self] in self?.hooks.install() }
        guide.model.onToggleLogin = { [weak self] in self?.toggleLogin() }
        return guide
    }()
    private let hider = MenuBarHider()
    private let list = MenuBarListController()
    /// Значки строки меню: их же показывает ряд закреплённых на острове.
    var iconModel: MenuBarListModel { list.model }
    /// Владелец включил или выключил плеер в меню.
    var onPlayerToggle: ((Bool) -> Void)?
    /// Обновления (nil — не настроены в этой сборке).
    var updater: AppUpdater? {
        didSet {
            list.model.onUpdate = { [weak self] in self?.updater?.checkForUpdates() }
            updater?.onAvailabilityChange = { [weak self] version in
                self?.list.model.updateVersion = version
                self?.updateIcon()
            }
        }
    }
    /// Сообщение автору об использовании (nil или недоступно — в этой сборке не используется).
    var telemetry: Telemetry?

    override init() {
        if Settings.hidesMenuBarIcons { MenuBarHider.seedPositions() }
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarLayout.controlIconLength)
        statusItem.autosaveName = MenuBarHider.controlName
        super.init()
        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        list.model.onNothingToHide = { [weak self] in self?.list.hide(); self?.showNothingToHide() }
        list.model.onShowMenu = { [weak self] in self?.showAppMenu() }
        hider.onStateChange = { [weak self] in self?.updateIcon(); self?.list.model.objectWillChange.send() }
        hider.onSafetyRevert = { [weak self] in self?.showSafetyAlert() }
        if Settings.hidesMenuBarIcons { hider.enable(control: statusItem); list.model.hider = hider }
        updateIcon()
        if CommandLine.arguments.contains("--debug-hider-selftest") { hider.selfTest() }
        if CommandLine.arguments.contains("--debug-hider-misalign-selftest") { hider.selfTestMisaligned() }
        if CommandLine.arguments.contains("--debug-open-setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showSetupGuide() }
        }
        if CommandLine.arguments.contains("--debug-open-icon-list") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let frame = self.iconFrame else { return }
                self.list.show(anchoredTo: frame)
            }
        }
    }

    // MARK: значок и клики

    private var iconFrame: NSRect? { statusItem.button?.window?.frame }

    /// Закрашенный знак — значки спрятаны, контурный — показаны.
    var glyphIsFilled: Bool { !hider.isEnabled || hider.isCollapsed }

    var glyphTip: String {
        let tip = hider.isEnabled
            ? (hider.isCollapsed ? "Значки спрятаны. Клик — показать, правый клик — настройка значков и меню" : "Значки показаны. Клик — спрятать, правый клик — настройка значков и меню")
            : "Клик — список значков, правый клик — настройка значков и меню"
        if let version = updater?.availableVersion { return "Доступна версия \(version). " + tip }
        return tip
    }

    /// Вид знака поменялся (его же показывает мини-знак в вырезе).
    var onIconChange: (() -> Void)?

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = ControlIcon.image(filled: glyphIsFilled)
        button.toolTip = glyphTip
        onIconChange?()
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        guard let frame = iconFrame else { return }
        glyphClicked(anchoredTo: frame, secondary: event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true)
    }

    /// Клик по знаку: по знаку в строке меню и по мини-знаку в вырезе одно и то же. `frame` — где стоит знак (под ним
    /// открывается панель).
    func glyphClicked(anchoredTo frame: NSRect, secondary: Bool) {
        if secondary {
            list.toggle(anchoredTo: frame)          // настройка значков; меню приложения — кнопка «Меню» в панели
            return
        }
        // Левый клик: прятать и возвращать значки. Если сворачивание выключено, показываем список — больше нечего делать.
        list.hide()
        guard hider.isEnabled else { list.show(anchoredTo: frame); return }
        if hider.toggle() == .nothingToHide { showNothingToHide() }
        updateIcon()
    }

    /// Меню приложения (хуки, обновления, автозапуск, выход) — из кнопки «Меню» в панели настройки значков.
    private func showAppMenu() {
        list.hide()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Окно «Настройка и подсказки»: что включить, чтобы всё работало, со статусом каждого шага.
    func showSetupGuide() {
        list.hide()
        guide.show()
    }

    private func showNothingToHide() {
        let alert = NSAlert()
        alert.messageText = "Левее знака topbar нет значков"
        alert.informativeText = "Прячется всё, что стоит левее знака topbar, а сейчас там пусто. Зажмите ⌘ и перетащите знак topbar правее значков, которые хотите прятать."
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showSafetyAlert() {
        let alert = NSAlert()
        alert.messageText = "Значки возвращены на место"
        alert.informativeText = "Знак topbar оказался там, где система не может его показать, и спрятался бы вместе с остальными. Освободите место в строке меню (закройте лишние значки) или перетащите знак topbar с зажатым ⌘ правее."
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for id in TerminalScripting.drivers.keys { AutomationAccess.shared.refresh(id, ask: false) }
        menu.removeAllItems()
        if let version = updater?.availableVersion {
            menu.addItem(item("Обновить до \(version)…", #selector(checkForUpdates)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Настройка и подсказки…", #selector(openSetupGuide)))
        menu.addItem(.separator())
        let status = NSMenuItem(title: "Хуки Claude Code: \(hooks.statusText())", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item("Установить хуки…", #selector(installHooks)))
        menu.addItem(item("Удалить хуки…", #selector(removeHooks)))
        // Строка на каждый терминал с точным определением вкладки: Ghostty всегда, остальные — пока запущены.
        for (id, driver) in TerminalScripting.drivers.sorted(by: { $0.value.name < $1.value.name })
        where id == TerminalScripting.ghostty || TerminalScripting.isRunning(id) {
            let line = NSMenuItem(title: AutomationAccess.shared.isGranted(id)
                ? "\(driver.name): точная вкладка определяется"
                : "\(driver.name): определяю по приложению (нет доступа «Автоматизация»)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let hiding = item("Сворачивать значки меню", #selector(toggleHiding))
        hiding.state = hider.isEnabled ? .on : .off
        menu.addItem(hiding)
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
            menu.addItem(item("Написать отзыв…", #selector(sendFeedback)))
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
    @objc func openSetupGuide() { showSetupGuide() }
    @objc func checkForUpdates() { updater?.checkForUpdates() }
    @objc func toggleShare() { guard let t = telemetry else { return }; t.setEnabled(!t.isEnabled) }
    @objc func changeName() { telemetry?.askName() }
    @objc func showWhatIsSent() { telemetry?.showWhatIsSent() }
    @objc func sendFeedback() { telemetry?.askFeedback() }

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

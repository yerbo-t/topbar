import AppKit
import ServiceManagement
import SwiftUI
import TopbarCore

/// Окно «Настройка topbar» для новых людей: что нужно включить, чтобы всё работало, с живым статусом каждого шага и кнопкой
/// рядом. Статусы обновляются сами, пока окно открыто.
@MainActor
final class SetupGuideModel: ObservableObject {
    struct TerminalState: Identifiable {
        let id: String
        let name: String
        let running: Bool
        let granted: Bool
    }

    @Published private(set) var hooksText = ""
    @Published private(set) var hooksHealthy = false
    @Published private(set) var accessGranted = false
    @Published private(set) var terminals: [TerminalState] = []
    @Published private(set) var launchAtLogin = false

    /// Кнопки шагов (их выполняет владелец приложения: окна подтверждения, запись настроек).
    var onInstallHooks: (() -> Void)?
    var onToggleLogin: (() -> Void)?
    var onClose: (() -> Void)?

    private let hooks: HooksController
    init(hooks: HooksController) { self.hooks = hooks }

    func refresh() {
        hooksText = hooks.statusText()
        hooksHealthy = hooks.isInstalledAndHealthy()
        accessGranted = MenuBarItemsProvider.isTrusted
        launchAtLogin = SMAppService.mainApp.status == .enabled
        var rows: [TerminalState] = []
        for (id, driver) in TerminalScripting.drivers.sorted(by: { $0.value.name < $1.value.name })
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            let running = TerminalScripting.isRunning(id)
            if running { AutomationAccess.shared.refresh(id, ask: false) }
            rows.append(TerminalState(id: id, name: driver.name, running: running, granted: AutomationAccess.shared.isGranted(id)))
        }
        terminals = rows
    }

    func requestAccess() {
        MenuBarItemsProvider.requestAccess()
        openSettings("Privacy_Accessibility")
    }

    func allowTerminal(_ id: String) {
        AutomationAccess.shared.refresh(id, ask: true)
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// Всё важное настроено: хуки стоят (остальное необязательно для работы острова).
    var essentialDone: Bool { hooksHealthy }
}

@MainActor
final class SetupGuideController {
    let model: SetupGuideModel
    private var window: NSWindow?
    private var timer: Timer?

    init(hooks: HooksController) {
        model = SetupGuideModel(hooks: hooks)
        model.onClose = { [weak self] in self?.close() }
    }

    var isShown: Bool { window?.isVisible == true }

    func show() {
        model.refresh()
        if window == nil {
            let host = NSHostingView(rootView: SetupGuideView(model: model))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SetupGuideView.width, height: SetupGuideView.height),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            win.title = "Настройка topbar"
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(red: 0.043, green: 0.043, blue: 0.055, alpha: 1)
            win.contentView = host
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { self?.timer?.invalidate(); return }
                self.model.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func close() {
        window?.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }
}

struct SetupGuideView: View {
    @ObservedObject var model: SetupGuideModel
    static let width: CGFloat = 560
    static let height: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Настройка topbar").font(.system(size: 22, weight: .bold))
                Text("Несколько шагов, чтобы всё работало. Галочки ставятся сами, как только вы всё сделаете.")
                    .font(.system(size: 13.5)).foregroundStyle(Look.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    hooksStep
                    accessStep
                    terminalsStep
                    loginStep
                    infoStep(title: "Найдите знак topbar в строке меню",
                             symbol: "rectangle.topthird.inset.filled",
                             lines: ["Клик по знаку прячет значки левее него и возвращает их обратно. Сами по себе значки не прячутся.",
                                     "Чтобы часть значков осталась на виду, зажмите ⌘ и перетащите знак левее них.",
                                     "Знака не видно? В строке меню на экранах с вырезом тесно: закройте лишние значки или перетащите знак правее."])
                    infoStep(title: "Как пользоваться",
                             symbol: "hand.tap",
                             lines: ["Наведите на вырез или кликните по нему: остров покажет сессии Claude Code. Клик по сессии откроет её терминал.",
                                     "Когда Claude просит разрешение, остров раскроется сам: «Разрешить» или «Отклонить» одним нажатием.",
                                     "Правый клик по знаку: настройка значков (закрепить, скрыть глазом) и меню приложения.",
                                     "Музыка: нажмите обложку в плеере, откроется приложение, из которого она играет."])
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }

            HStack {
                Text("Окно можно открыть снова: правый клик по знаку → «Меню» → «Настройка и подсказки».")
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Готово") { model.onClose?() }.buttonStyle(PillButtonStyle(kind: .light)).fixedSize()
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    // MARK: шаги

    private var hooksStep: some View {
        StepCard(number: 1, title: "Подключите Claude Code", state: model.hooksHealthy ? .done : .todo) {
            Text("topbar узнаёт о сессиях через хуки: небольшую запись в настройках Claude Code. Перед записью вы увидите, что именно изменится, и сможете отказаться.")
            if model.hooksHealthy {
                Text("Хуки установлены. Сессии, запущенные раньше, подхватят их после перезапуска: закройте claude и откройте снова.").foregroundStyle(Look.allow)
            } else {
                if model.hooksText != "не установлены" { Text("Состояние: \(model.hooksText).").foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25)) }
                Button(model.hooksText == "не установлены" ? "Показать изменения" : "Переустановить хуки…") { model.onInstallHooks?() }
                    .buttonStyle(PillButtonStyle(kind: .light)).fixedSize()
            }
        }
    }

    private var accessStep: some View {
        StepCard(number: 2, title: "Разрешите доступ к значкам строки меню", state: model.accessGranted ? .done : .todo) {
            Text("Нужен «Универсальный доступ», чтобы список показывал значки других приложений и нажимал их по вашему клику. Приложение ничего не записывает и никуда не отправляет.")
            if model.accessGranted {
                Text("Доступ есть.").foregroundStyle(Look.allow)
            } else {
                HStack(spacing: 10) {
                    Button("Дать доступ") { model.requestAccess() }.buttonStyle(PillButtonStyle(kind: .light)).fixedSize()
                    Button("Открыть настройки") { model.openSettings("Privacy_Accessibility") }.buttonStyle(PillButtonStyle(kind: .neutral)).fixedSize()
                }
                Text("Включили, а статус не меняется? В настройках выделите topbar, нажмите «−», затем «+» и добавьте приложение заново.")
                    .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.55))
            }
        }
    }

    private var terminalsStep: some View {
        let missing = model.terminals.contains { !$0.granted }
        return StepCard(number: 3, title: "Разрешите управлять терминалом", state: model.terminals.isEmpty ? .optional : (missing ? .todo : .done)) {
            Text("Тогда по клику на сессию откроется именно её вкладка. Без этого topbar просто выводит приложение терминала вперёд. Разрешение нужно один раз для каждого терминала. Warp, WezTerm, kitty, VS Code, Cursor и другие работают и без него.")
            if model.terminals.isEmpty {
                Text("Ghostty, Terminal и iTerm2 не найдены, этот шаг не нужен.").foregroundStyle(Color(white: 0.55))
            }
            ForEach(model.terminals) { terminal in
                HStack(spacing: 10) {
                    Image(systemName: terminal.granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(terminal.granted ? Look.allow : Color(white: 0.4))
                    Text(terminal.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if terminal.granted {
                        Text("разрешено").font(.system(size: 12)).foregroundStyle(Look.allow)
                    } else if terminal.running {
                        Button("Разрешить") { model.allowTerminal(terminal.id) }.buttonStyle(PillButtonStyle(kind: .light)).fixedSize()
                    } else {
                        Text("откройте \(terminal.name), затем вернитесь сюда").font(.system(size: 12)).foregroundStyle(Color(white: 0.55))
                    }
                }
            }
            if missing {
                HStack(spacing: 8) {
                    Text("Окно с вопросом не появилось? Включите topbar вручную:").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.55))
                    Button("Открыть настройки") { model.openSettings("Privacy_Automation") }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Look.tool)
                }
            }
        }
    }

    private var loginStep: some View {
        StepCard(number: 4, title: "Запускайте topbar при входе", state: model.launchAtLogin ? .done : .optional) {
            Text("Чтобы остров был на месте после перезагрузки. Приложение должно лежать в папке «Программы».")
            if model.launchAtLogin {
                Text("Включено.").foregroundStyle(Look.allow)
            } else {
                Button("Включить") { model.onToggleLogin?() }.buttonStyle(PillButtonStyle(kind: .neutral)).fixedSize()
            }
        }
    }

    private func infoStep(title: String, symbol: String, lines: [String]) -> some View {
        StepCard(symbol: symbol, title: title, state: .info) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Color(white: 0.45))
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Карточка шага: номер или значок, заголовок, статус справа, внутри пояснение и кнопки.
struct StepCard<Content: View>: View {
    enum State { case done, todo, optional, info }

    var number: Int?
    var symbol: String?
    let title: String
    let state: State
    @ViewBuilder let content: Content

    init(number: Int, title: String, state: State, @ViewBuilder content: () -> Content) {
        self.number = number; self.symbol = nil; self.title = title; self.state = state; self.content = content()
    }

    init(symbol: String, title: String, state: State, @ViewBuilder content: () -> Content) {
        self.number = nil; self.symbol = symbol; self.title = title; self.state = state; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(state == .done ? Look.allow : Color.white.opacity(0.1)).frame(width: 26, height: 26)
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Look.allowInk)
                    } else if let number {
                        Text("\(number)").font(.system(size: 12.5, weight: .bold))
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    }
                }
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                switch state {
                case .done: Text("готово").font(.system(size: 12)).foregroundStyle(Look.allow)
                case .todo: Text("нужно").font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
                case .optional: Text("по желанию").font(.system(size: 12)).foregroundStyle(Look.muted)
                case .info: EmptyView()
                }
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .font(.system(size: 12.5)).foregroundStyle(Look.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
    }
}

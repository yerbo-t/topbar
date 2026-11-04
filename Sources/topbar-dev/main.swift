import Foundation
import TopbarCore

// Консоль разработчика: слушает хуки, печатает сессии, отвечает на запросы разрешений с клавиатуры.
// Нужна, пока нет окна острова; для проверки ядра и моста на настоящих сессиях Claude Code.

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    topbar-dev run [--verbose]
        слушать хуки и показывать сессии; на запрос разрешения отвечать y (разрешить) или n (отклонить);
        --verbose печатает каждое событие (есть ли tool_use_id, терминал, признаки окна)
    topbar-dev install-bridge --from <путь к topbar-hook>
        скопировать мост в стабильное место
    topbar-dev install --settings <settings.json> [--yes]
        показать, что изменится в файле, и вписать хуки
    topbar-dev uninstall --settings <settings.json>
        убрать хуки topbar
    topbar-dev status --settings <settings.json>
        установлены ли хуки и существует ли мост, на который они ссылаются
    """)
    exit(2)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "run":
    setvbuf(stdout, nil, _IOLBF, 0)   // построчный вывод, даже когда stdout — файл или pipe
    let verbose = args.contains("--verbose")
    let hub = SessionHub(socketPath: Paths.socketPath)
    var open: [PermissionRequest] = []   // трогаем только на hub.callbackQueue
    let out = hub.callbackQueue

    hub.onRequestOpened = { request, session in
        open.append(request)
        let agent = request.agentType.map { " (субагент \($0))" } ?? ""
        print("\n? [\(session.project)]\(agent) \(request.toolName):\n\(request.detail)\n  ответ: y — разрешить, n — отклонить")
        fflush(stdout)
    }
    hub.onRequestClosed = { id in
        open.removeAll { $0.requestId == id }
        print("  (запрос закрыт: \(id.prefix(6)))")
    }
    hub.onSessionDone = { session in
        print("\u{7}✓ готово: \(session.project)")
    }
    hub.onEvent = { msg in
        guard verbose else { return }
        let e = msg.event
        print("  · \(e.hookEventName) tool=\(e.toolName ?? "-") tool_use_id=\(e.toolUseId ?? "нет") pid=\(msg.pid) tty=\(msg.tty ?? "-") term=\(msg.termProgram ?? "-") unattended=\(msg.unattended) hints=\(msg.hints)")
    }
    hub.onChange = { sessions in
        let titles = SessionStore.displayTitles(sessions)
        let counts = Dictionary(grouping: sessions, by: \.status).mapValues(\.count)
        print("\n— ждёт \(counts[.waitingPermission] ?? 0) · работает \(counts[.working] ?? 0) · готово \(counts[.done] ?? 0) · простаивает \(counts[.idle] ?? 0) —")
        for s in sessions {
            let label: String
            switch s.status {
            case .waitingPermission: label = "ЖДЁТ  "
            case .working: label = "работает"
            case .done: label = "готово "
            case .idle: label = "простаивает"
            }
            print("  \(label)  \(titles[s.sessionId] ?? s.project)  \(s.currentAction)  [\(s.hostApp ?? "?")]")
        }
        fflush(stdout)
    }
    do { try hub.start() } catch SocketError.alreadyRunning {
        fail("сокет \(Paths.socketPath) уже слушает другой экземпляр")
    } catch { fail("не удалось открыть сокет \(Paths.socketPath): \(error)") }
    print("слушаю \(Paths.socketPath)")

    Thread.detachNewThread {
        while let line = readLine() {
            let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "n" else { continue }
            out.async {
                guard let request = open.first else { print("  (нет открытых запросов)"); return }
                open.removeFirst()
                hub.decide(requestId: request.requestId, allow: answer == "y") { delivered in
                    print(delivered
                        ? "  → \(answer == "y" ? "разрешено" : "отклонено"): \(request.summary)"
                        : "  → не доставлено (запрос уже закрыт): \(request.summary)")
                }
            }
        }
    }
    dispatchMain()

case "install-bridge":
    guard let from = value(after: "--from", in: args) else { usage() }
    let target = Paths.bridgeInstallPath
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.copyItem(atPath: from, toPath: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
    } catch { fail("не удалось скопировать мост: \(error)") }
    print("мост установлен: \(target)")

case "install", "uninstall", "status":
    guard let settings = value(after: "--settings", in: args) else { usage() }
    let old = SettingsFile.read(settings)
    do {
        switch command {
        case "status":
            guard HookInstaller.isInstalled(in: old) else { print("хуки не установлены"); break }
            print("хуки установлены")
            for path in HookInstaller.bridgePaths(in: old).sorted() {
                let exists = FileManager.default.isExecutableFile(atPath: path)
                print(exists ? "  мост на месте: \(path)" : "  ВНИМАНИЕ: моста нет по пути \(path) — каждое событие будет падать с ошибкой")
            }
        case "install":
            guard FileManager.default.isExecutableFile(atPath: Paths.bridgeInstallPath) else {
                fail("сначала: topbar-dev install-bridge --from <путь к topbar-hook>")
            }
            let new = try HookInstaller.install(into: old, bridgePath: Paths.bridgeInstallPath)
            if HookInstaller.willReformat(old) {
                print("ВНИМАНИЕ: файл будет переформатирован — ключи отсортируются, отступы станут единообразными.")
            }
            print(HookInstaller.diff(old: old, new: new))
            if !args.contains("--yes") {
                print("\nЗаписать в \(settings)? [y/N] ", terminator: "")
                guard readLine()?.lowercased() == "y" else { print("отменено"); exit(0) }
            }
            try SettingsFile.write(new, to: settings)
            print("хуки вписаны")
        default:
            guard let old else { fail("нет файла \(settings)") }
            let new = try HookInstaller.remove(from: old)
            try SettingsFile.write(new, to: settings)
            print("хуки убраны")
        }
    } catch HookInstaller.InstallError.unexpectedShape(let key) {
        fail("в файле неожиданный вид раздела «\(key)»; ничего не изменено")
    } catch { fail("ошибка: \(error)") }

default:
    usage()
}

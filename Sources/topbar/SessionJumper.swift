import AppKit
import TopbarCore

/// Перенос владельца к сессии. Ghostty, Terminal и iTerm2 — к нужной вкладке и окну (нужно разрешение «Автоматизация»);
/// редакторы вроде VS Code и Cursor — к окну проекта; любое другое приложение просто выходит вперёд.
@MainActor
enum SessionJumper {
    static func open(_ session: Session) {
        guard let bundleId = hostBundleId(of: session) else { return }
        if let tty = session.tty, TerminalScripting.supports(bundleId) {
            if TerminalScripting.focus(bundleId: bundleId, tty: tty) {
                activate(bundleId)
                return
            }
            // Доступа ещё нет — спросим (система покажет вопрос один раз); пока выводим приложение вперёд.
            AutomationAccess.shared.refresh(bundleId, ask: true)
        }
        if TerminalHost.isEditor(bundleId: bundleId), !session.projectRoot.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open([URL(fileURLWithPath: session.projectRoot)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        activate(bundleId)
    }

    /// Приложение сессии: сообщённое хостом; если его нет (терминал не сказал) — приложение с окном среди предков процесса
    /// `claude`, так находится любой терминал.
    static func hostBundleId(of session: Session) -> String? {
        if let known = WatchPolicy.hostBundleId(of: session) { return known }
        return windowedAppBundleId(ancestorOf: session.pid)
    }

    static func windowedAppBundleId(ancestorOf pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular,
               let id = app.bundleIdentifier { return id }
            guard let parent = ProcessProbe.parentPid(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func activate(_ bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
    }
}

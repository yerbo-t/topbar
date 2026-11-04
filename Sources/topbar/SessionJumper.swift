import AppKit
import TopbarCore

/// Перенос владельца к сессии: Ghostty — выходит на передний план приложение, VS Code — окно проекта.
enum SessionJumper {
    static func open(_ session: Session) {
        guard let bundleId = WatchPolicy.bundleId(forHost: session.hostApp) else { return }
        if session.hostApp == "VS Code", !session.projectRoot.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open([URL(fileURLWithPath: session.projectRoot)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
    }
}

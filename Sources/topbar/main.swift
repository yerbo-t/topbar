import AppKit

// Приложение без значка в Dock: остров у выреза и иконка в строке меню.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

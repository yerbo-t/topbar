import AppKit
import SwiftUI

/// Панель со списком значков строки меню под управляющим значком; закрывается кликом вне неё.
@MainActor
final class MenuBarListController {
    let model = MenuBarListModel()
    private let panel: NSPanel
    private var monitor: Any?
    private var anchor = NSRect.zero

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: MenuBarListView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        model.onClose = { [weak self] in self?.hide() }
    }

    var isShown: Bool { panel.isVisible }

    func toggle(anchoredTo rect: NSRect) {
        isShown ? hide() : show(anchoredTo: rect)
    }

    func show(anchoredTo rect: NSRect) {
        anchor = rect
        model.message = nil
        model.refresh()
        layout()
        panel.orderFrontRegardless()
        // Список перерисовывается по мере поступления данных — подгоняем высоту и положение.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.layout() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.layout() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func layout() {
        guard panel.isVisible || anchor != .zero else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let width = MenuBarListView.width
        var height: CGFloat = 40 + 52          // шапка и подвал
        if !model.trusted {
            height += 120
        } else if model.entries.isEmpty {
            height += 80
        } else {
            height += MenuBarListView.listHeight(rows: model.entries.count)
        }
        if model.message != nil { height += 44 }
        let x = min(max(anchor.midX - width / 2, frame.minX + 8), frame.maxX - width - 8)
        let y = anchor.minY - height - 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

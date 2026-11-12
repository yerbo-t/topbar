import AppKit
import SwiftUI

/// Панель со списком значков строки меню под управляющим значком; закрывается кликом вне неё.
@MainActor
final class MenuBarListController {
    let model = MenuBarListModel()
    private let panel: NSPanel
    private var monitor: Any?
    private var trustTimer: Timer?
    private var anchor = NSRect.zero

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Панель встаёт на тот стол, где по знаку кликнули, а не «на все столы»: спрятанное окно «на всех столах» система
        // может оставить лишь на части столов, и новый показ его на текущий не возвращает. 2026-11-12 у владельца окно
        // осталось на двух полноэкранных столах (отчего — не найдено), и правый клик показывал список там, а не на экране.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: MenuBarListView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        model.onClose = { [weak self] in self?.hide() }
        model.onResize = { [weak self] in self?.layout() }
    }

    /// Видна на текущем столе. Оставшаяся открытой на другом столе не в счёт: клик по знаку должен её показать, а не спрятать.
    var isShown: Bool { panel.isVisible && panel.isOnActiveSpace }

    func toggle(anchoredTo rect: NSRect) {
        isShown ? hide() : show(anchoredTo: rect)
    }

    func show(anchoredTo rect: NSRect) {
        anchor = rect
        model.message = nil
        model.refresh()
        layout()
        // Открытую на другом столе панель показываем заново: на текущий стол её переносит именно показ.
        if panel.isVisible { panel.orderOut(nil) }
        panel.orderFrontRegardless()
        // Список перерисовывается по мере поступления данных — подгоняем высоту и положение.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.layout() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.layout() }
        // Пока доступа нет, раз в секунду проверяем, не включил ли его владелец в настройках.
        trustTimer?.invalidate()
        if !model.trusted {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.recheckAccess()
                    if self.model.trusted { self.trustTimer?.invalidate(); self.trustTimer = nil }
                    self.layout()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            trustTimer = timer
        }
        // Показ поверх уже открытой (на другом столе) панели: прежний монитор снимаем, иначе он остался бы навсегда.
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
    }

    func hide() {
        trustTimer?.invalidate()
        trustTimer = nil
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func layout() {
        guard panel.isVisible || anchor != .zero else { return }
        // Окно знака может быть не на экране (полноэкранное окно прячет строку меню): тогда панель — у верхнего правого угла.
        var anchor = anchor
        var screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
        if screen == nil, let main = NSScreen.main {
            screen = main
            anchor = NSRect(x: main.frame.maxX - 60, y: main.frame.maxY - 24, width: 36, height: 24)
        }
        guard let frame = screen?.frame else { return }
        let width = MenuBarListView.width
        var height: CGFloat = 40 + 104         // шапка и подвал (подсказка и кнопки)
        if !model.trusted {
            height += 190
        } else if model.entries.isEmpty {
            height += 80
        } else {
            height += MenuBarListView.listHeight(content: model.contentHeight)
        }
        if model.message != nil { height += 44 }
        if model.updateVersion != nil { height += 52 }       // кнопка «Обновить до …»
        if model.hidingTitle != nil { height += 52 }       // крупная кнопка «Спрятать / Показать значки»
        let x = min(max(anchor.midX - width / 2, frame.minX + 8), frame.maxX - width - 8)
        let y = anchor.minY - height - 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

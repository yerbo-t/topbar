import AppKit
import SwiftUI
import Combine

/// Прозрачное окно без рамки у выреза встроенного экрана. Размер и видимость следуют за состоянием острова.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandPanelController {
    private let panel = IslandPanel()
    private let model: IslandViewModel

    init(model: IslandViewModel) {
        self.model = model
        let host = NSHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        model.onLayoutChange = { [weak self] in self?.layout() }
        // Значки в строке меню появляются и пропадают сами; пока остров свёрнут, следим за свободным местом.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.mode == .collapsed else { return }
                if self.model.refreshMenuBarSpace() { self.layout() }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        spaceTimer = timer
    }

    private var spaceTimer: Timer?

    /// Пересчитать окно по текущему состоянию.
    func layout() {
        model.geometry = NotchGeometry.find()
        if model.mode == .collapsed { model.refreshMenuBarSpace() }
        model.recomputeLayout()
        guard let geometry = model.geometry, model.mode != .hidden else {
            panel.orderOut(nil)
            return
        }
        let size = model.size
        let screen = geometry.screen.frame
        let frame = NSRect(x: screen.midX + model.centerShift - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }
}

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
        // Другое приложение — другие меню слева от выреза: место перемеряем сразу, не дожидаясь таймера (к этому уведомлению
        // строка меню уже принадлежит новому приложению). Значки справа от смены приложения не меняются и тут не меряются.
        // Тяжёлое приложение (Zoom) в момент перехода меню не отдаёт — тогда уши остались бы от прежнего, пока таймер
        // не подтвердит место дважды (до 5 с); поэтому меряем ещё дважды, когда меню уже прочитаются.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.remeasureLeft()
                for delay in [0.5, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.remeasureLeft() }
                }
            }
        }
    }

    private func remeasureLeft() {
        guard model.mode == .collapsed else { return }
        if model.refreshMenuBarSpace(force: true, immediate: true, onlyLeft: true) { layout() }
    }

    private var spaceTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private var settleWork: DispatchWorkItem?
    private var hideCheck: DispatchWorkItem?
    private let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)

    /// Пересчитать окно по текущему состоянию. Остров «вырастает из выреза»: окно на время перехода покрывает и старую, и новую
    /// фигуру, а саму фигуру двигает пружина SwiftUI; когда она успокоилась, окно сжимается до итогового размера (иначе прозрачная
    /// часть окна перехватывала бы клики).
    func layout() {
        model.geometry = NotchGeometry.find()
        if model.mode == .collapsed { model.refreshMenuBarSpace() }
        model.recomputeLayout()
        settleWork?.cancel()
        guard let geometry = model.geometry, model.mode != .hidden else {
            // Экран с вырезом на миг пропадает из списка при переходе между столами: остров сразу не прячем, а проверяем снова.
            if model.geometry == nil, model.mode != .hidden, panel.isVisible {
                hideCheck?.cancel()
                let check = DispatchWorkItem { [weak self] in
                    guard let self, NotchGeometry.find() == nil else { return }
                    self.hide()
                }
                hideCheck = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: check)
                return
            }
            hide()
            return
        }
        let size = model.size
        let screen = geometry.screen.frame
        let target = NSRect(x: screen.midX + model.centerShift - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
        let shapeTarget = ShapeRect(x: 0, width: size.width, height: size.height, radius: model.cornerRadius)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if !panel.isVisible {
            // Первое появление: из выреза в нужный размер.
            panel.setFrame(target, display: true)
            let notch = ShapeRect(x: (size.width - geometry.notchWidth) / 2, width: geometry.notchWidth, height: geometry.notchHeight, radius: 11)
            model.shape = reduceMotion ? shapeTarget : notch
            panel.orderFrontRegardless()
            if !reduceMotion {
                DispatchQueue.main.async { [self] in withAnimation(spring) { model.shape = shapeTarget } }
            }
            return
        }

        let old = panel.frame
        if reduceMotion || (old.size == target.size && old.origin == target.origin) {
            panel.setFrame(target, display: true)
            model.shape = shapeTarget
            return
        }
        // Окно = объединение, фигура пока на прежнем месте — прыжка нет; следующим проходом пружина ведёт её к новой.
        let union = old.union(target)
        let oldShape = model.shape
        model.shape = ShapeRect(x: old.minX - union.minX + oldShape.x, width: oldShape.width, height: oldShape.height, radius: oldShape.radius)
        panel.setFrame(union, display: true)
        let moved = ShapeRect(x: target.minX - union.minX, width: target.width, height: target.height, radius: model.cornerRadius)
        DispatchQueue.main.async { [self] in withAnimation(spring) { model.shape = moved } }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.setFrame(target, display: true)
            self.model.shape = shapeTarget      // та же картинка: окно сдвинулось ровно на смещение фигуры
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Убрать остров: фигура сжимается в вырез, потом окно скрывается.
    private func hide() {
        guard panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || model.geometry == nil {
            panel.orderOut(nil)
            return
        }
        let notchWidth = model.geometry?.notchWidth ?? 200
        let notchHeight = model.geometry?.notchHeight ?? 32
        let current = model.shape
        withAnimation(spring) {
            model.shape = ShapeRect(x: current.x + (current.width - notchWidth) / 2, width: notchWidth, height: notchHeight, radius: 11)
        }
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

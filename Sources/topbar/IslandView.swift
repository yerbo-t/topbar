import AppKit
import SwiftUI
import TopbarCore

extension SessionStatus {
    var color: Color {
        switch self {
        case .waitingPermission: return Color(red: 1.0, green: 0.70, blue: 0.25)
        case .working: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .done: return Color(red: 0.27, green: 0.78, blue: 0.47)
        case .idle: return Color(white: 0.58)
        }
    }

    var label: String {
        switch self {
        case .waitingPermission: return "ждёт разрешения"
        case .working: return "работает"
        case .done: return "готово"
        case .idle: return "простаивает"
        }
    }
}

/// Точка статуса. Мигание «ждёт» рисует Core Animation в отдельном процессе системы: анимация на SwiftUI
/// держала бы приложение на ~3% процессора всё время ожидания.
struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Group {
            if status == .waitingPermission {
                PulsingDot(color: NSColor(status.color))
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.layer?.backgroundColor = color.cgColor
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(pulse, forKey: "pulse")
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct IslandView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        let shape = model.shape
        let outline = UnevenRoundedRectangle(bottomLeadingRadius: shape.radius, bottomTrailingRadius: shape.radius)
        ZStack(alignment: .top) {
            outline.fill(Color.black)
            if model.mode != .collapsed {
                // Тонкая кромка только по бокам и снизу: сверху остров должен сливаться с вырезом.
                outline.strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.10)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            content
                .id(model.mode)
                .transition(.opacity)
        }
        .frame(width: shape.width, height: shape.height, alignment: .top)
        .clipShape(outline)
        .offset(x: shape.x)
        .foregroundStyle(.white)
        .onHover { model.hover($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .hidden: EmptyView()
        case .collapsed: CollapsedView(model: model)
        case .list: ListView(model: model)
        case .card: CardView(model: model)
        }
    }
}

struct CollapsedView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        let ears = model.ears
        let notchW = model.geometry?.notchWidth ?? 200
        HStack(spacing: 0) {
            ear(ears.left, style: ears.style, alignment: .trailing, width: ears.leftWidth)
            Spacer().frame(width: notchW)
            ear(ears.right, style: ears.style, alignment: .leading, width: ears.rightWidth)
        }
        .frame(height: model.geometry?.notchHeight ?? 32)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleList() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.presenter.summaryText.isEmpty ? "Сессии Claude Code" : model.presenter.summaryText)
        .accessibilityAddTraits(.isButton)
    }

    private func ear(_ chips: [SummaryChip], style: EarStyle, alignment: Alignment, width: CGFloat) -> some View {
        HStack(spacing: style == .dots ? 6 : 10) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: style == .full ? 6 : 4) {
                    StatusDot(status: chip.status)
                    switch style {
                    case .full: Text(chip.text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    case .compact, .merged: Text("\(chip.count)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    case .dots: EmptyView()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .fixedSize()
        .frame(width: width, alignment: alignment)
        .clipped()
    }
}

struct ListView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: (model.geometry?.notchHeight ?? 32) + 6)
            ForEach(model.presenter.sessions, id: \.sessionId) { session in
                Button { model.rowTapped(session) } label: { RowView(session: session, title: model.titles[session.sessionId] ?? session.project) }
                    .buttonStyle(RowButtonStyle())
            }
            HStack {
                Text("\(model.presenter.sessions.count) \(plural(model.presenter.sessions.count))")
                Spacer()
                Button("Свернуть") { model.collapse() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(white: 0.62))
            .padding(.horizontal, 24)
            .frame(height: 36)
        }
        .padding(.horizontal, 6)
    }

    private func plural(_ n: Int) -> String {
        let r10 = n % 10, r100 = n % 100
        if r10 == 1 && r100 != 11 { return "сессия" }
        if (2...4).contains(r10) && !(12...14).contains(r100) { return "сессии" }
        return "сессий"
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12).fill(configuration.isPressed ? Color(white: 0.16) : Color.clear))
            .contentShape(Rectangle())
    }
}

struct RowView: View {
    let session: Session
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(session.currentAction.isEmpty ? (session.hostApp ?? "") : session.currentAction)
                    .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.66)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(session.status.label)
                .font(.system(size: 11.5))
                .foregroundStyle(session.status == .idle ? Color(white: 0.66) : session.status.color)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .accessibilityElement(children: .combine)
    }
}

struct CardView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        if let card = model.presenter.currentCard {
            let title = model.titles[card.session.sessionId] ?? card.session.project
            VStack(alignment: .leading, spacing: 8) {
                Spacer().frame(height: (model.geometry?.notchHeight ?? 32) + 2)
                HStack {
                    Text("Запрос разрешения").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let mode = card.session.permissionMode, mode != "default" {
                        Text("режим: \(mode)").font(.system(size: 11)).foregroundStyle(Color(white: 0.66))
                    }
                }
                HStack(spacing: 6) {
                    Text(title).foregroundStyle(Color(white: 0.7))
                    if let agent = card.request.agentType { Text("· субагент \(agent)").foregroundStyle(Color(white: 0.7)) }
                }
                .font(.system(size: 12)).lineLimit(1)
                Text(card.request.toolName).font(.system(size: 11)).foregroundStyle(Color(white: 0.66))
                ScrollView {
                    Text(card.request.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.09)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.16)))
                HStack(spacing: 8) {
                    Button("Разрешить") { model.decide(allow: true) }
                        .buttonStyle(CardButtonStyle(prominent: true)).fixedSize()
                    Button("Отклонить") { model.decide(allow: false) }
                        .buttonStyle(CardButtonStyle(prominent: false)).fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    Button("Перейти к сессии") { model.jump(to: card.session) }
                    Button("Свернуть") { model.dismissCard() }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color(white: 0.66))
                Text(model.presenter.queuedBehindCurrent > 0
                     ? "Ответить можно и в терминале. В очереди ещё \(model.presenter.queuedBehindCurrent)."
                     : "Ответить можно и в самом терминале.")
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.55))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(RoundedRectangle(cornerRadius: 10).fill(prominent ? Color(white: 0.92) : Color(white: 0.16)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

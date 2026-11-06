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
        let mediaOnly = model.presenter.mediaActive && model.presenter.summaryChips.isEmpty
        HStack(spacing: 0) {
            if mediaOnly {
                ArtworkView(image: model.artwork, size: 20, radius: 5).frame(width: ears.leftWidth)
                Spacer().frame(width: notchW)
                EqualizerView(playing: model.nowPlaying?.playing ?? false).frame(width: 14, height: 12)
                    .frame(width: ears.rightWidth).clipped()
            } else {
                ear(ears.left, style: ears.style, alignment: .trailing, width: ears.leftWidth)
                Spacer().frame(width: notchW)
                ear(ears.right, style: ears.style, alignment: .leading, width: ears.rightWidth)
            }
        }
        .frame(height: model.geometry?.notchHeight ?? 32)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleList() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.presenter.summaryText.isEmpty ? (model.nowPlaying?.title ?? "Сессии Claude Code") : model.presenter.summaryText)
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
            let offset = model.presenter.mediaActive ? 1 : 0
            if model.presenter.mediaActive {
                PlayerView(model: model).riseIn(0)
            }
            ForEach(Array(model.presenter.sessions.enumerated()), id: \.element.sessionId) { index, session in
                Button { model.rowTapped(session) } label: { RowView(session: session, title: model.titles[session.sessionId] ?? session.project) }
                    .buttonStyle(RowButtonStyle())
                    .riseIn(index + offset)
            }
            HStack {
                if !model.presenter.sessions.isEmpty {
                    Text("\(model.presenter.sessions.count) \(plural(model.presenter.sessions.count))")
                }
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
            .background(RoundedRectangle(cornerRadius: 14).fill(configuration.isPressed ? Color(white: 0.16) : Color.clear))
            .contentShape(Rectangle())
    }
}

struct RowView: View {
    let session: Session
    let title: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                sessionTitle(title, size: 14).lineLimit(1)
                Text(session.currentAction.isEmpty ? (session.hostApp ?? "") : session.currentAction)
                    .font(.system(size: 11.5)).foregroundStyle(Look.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(session.status.label)
                .font(.system(size: 11.5))
                .foregroundStyle(session.status == .idle ? Look.muted : session.status.color)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        // Строке, которой нужно внимание (ждёт разрешения), — заметная подсветка, остальным — только под курсором.
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(session.status == .waitingPermission ? Look.hot : (hovering ? Color.white.opacity(0.05) : .clear)))
        .onHover { hovering = $0 }
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
                HStack(spacing: 10) {
                    StatusDot(status: .waitingPermission)
                    sessionTitle(title, size: 14).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(headerNote(card)).font(.system(size: 11.5)).foregroundStyle(Look.muted).lineLimit(1)
                }
                ScrollView {
                    (Text(card.request.toolName).foregroundColor(Look.tool) + Text("  " + card.request.detail).foregroundColor(Look.code))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Look.codeFill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Look.codeLine))
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("Отклонить") { model.decide(allow: false) }
                        .buttonStyle(PillButtonStyle(kind: .neutral)).fixedSize()
                    Button("Разрешить") { model.decide(allow: true) }
                        .buttonStyle(PillButtonStyle(kind: .allow)).fixedSize()
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
            .riseIn(0)
        }
    }

    /// «просит разрешение», а у субагента и особого режима — с пометкой (проект и ветка уже в подписи слева).
    private func headerNote(_ card: (request: PermissionRequest, session: Session)) -> String {
        var parts: [String] = []
        if let agent = card.request.agentType { parts.append("субагент \(agent)") }
        if let mode = card.session.permissionMode, mode != "default" { parts.append("режим \(mode)") }
        parts.append("просит разрешение")
        return parts.joined(separator: " · ")
    }
}

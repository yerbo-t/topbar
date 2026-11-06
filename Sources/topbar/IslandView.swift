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
            if mediaOnly, ears.leftWidth == 0 {
                // Меню приложения вплотную к вырезу: обложка справа, слева ничего не накрываем.
                Spacer().frame(width: notchW)
                ArtworkView(image: model.artwork, size: 18, radius: 5).frame(width: ears.rightWidth)
            } else if mediaOnly {
                ArtworkView(image: model.artwork, size: 20, radius: 5).frame(width: ears.leftWidth)
                Spacer().frame(width: notchW)
                EqualizerView(playing: model.nowPlaying?.playing ?? false).frame(width: 14, height: 12)
                    .frame(width: ears.rightWidth).clipped()
            } else {
                ear(ears.left, style: ears.style, alignment: .trailing, width: ears.leftWidth)
                Spacer().frame(width: notchW)
                rightEar(ears)
            }
        }
        .frame(height: model.geometry?.notchHeight ?? 32)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleList() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.presenter.summaryText.isEmpty ? (model.nowPlaying?.title ?? "Сессии Claude Code") : model.presenter.summaryText)
        .accessibilityAddTraits(.isButton)
    }

    /// Правое ухо: пункты сводки и, если играет музыка, а слева уже слова, обложка трека (на паузе приглушена).
    @ViewBuilder private func rightEar(_ ears: EarLayout) -> some View {
        let playing = model.nowPlaying?.playing ?? false
        if !ears.showsMedia {
            ear(ears.right, style: ears.style, alignment: .leading, width: ears.rightWidth)
        } else if ears.right.isEmpty {
            ArtworkView(image: model.artwork, size: 18, radius: 5).opacity(playing ? 1 : 0.55)
                .frame(width: ears.rightWidth)
        } else {
            HStack(spacing: 0) {
                ear(ears.right, style: ears.style, alignment: .leading, width: ears.rightWidth - EarLayout.mediaSlot)
                ArtworkView(image: model.artwork, size: 18, radius: 5).opacity(playing ? 1 : 0.55)
                    .frame(width: EarLayout.mediaSlot, alignment: .leading)
            }
            .frame(width: ears.rightWidth)
        }
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
                Button { model.rowTapped(session) } label: { RowView(session: session, label: model.label(for: session)) }
                    .buttonStyle(RowButtonStyle())
                    .riseIn(index + offset)
            }
            HStack {
                if !model.presenter.sessions.isEmpty {
                    Text("\(model.presenter.sessions.count) \(plural(model.presenter.sessions.count))")
                }
                Spacer()
                Button("Свернуть") { model.collapse() }.buttonStyle(QuietButtonStyle(compact: true))
            }
            .font(.system(size: 11))
            .foregroundStyle(Look.muted)
            .padding(.leading, 24).padding(.trailing, 14)
            .frame(height: 40)
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
    let label: SessionLabel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                // Крупно имя сессии, рядом спокойно проект (или ветка, если крупно уже проект).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let aside = label.project ?? label.branch {
                        Text(aside).font(.system(size: 12)).foregroundStyle(Look.muted).lineLimit(1).fixedSize()
                    }
                }
                Text(secondLine).font(.system(size: 11.5)).foregroundStyle(Look.muted).lineLimit(1)
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

    /// Что сессия делает сейчас; если ничего — где она (ветка, если её не видно выше, и приложение).
    private var secondLine: String {
        if !session.currentAction.isEmpty { return session.currentAction }
        let branch = label.project != nil ? label.branch : nil
        return [branch, session.hostApp].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Размеры карточки разрешения: по ним и рисуется вид, и считается высота острова.
enum CardMetrics {
    static let width: CGFloat = 480
    static let hPad: CGFloat = 20
    static var inner: CGFloat { width - 2 * hPad }
    static let top: CGFloat = 8
    static let titleLine: CGFloat = 17
    static let contextLine: CGFloat = 16
    static let afterHeader: CGFloat = 14
    static let questionLine: CGFloat = 17
    static let purposeGap: CGFloat = 3
    static let purposeLine: CGFloat = 15
    static let beforeCode: CGFloat = 10
    static let codePad: CGFloat = 10
    static let codeLine: CGFloat = 16
    static let beforeActions: CGFloat = 14
    static let actions: CGFloat = 34
    static let bottom: CGFloat = 16

    static let questionFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    static let purposeFont = NSFont.systemFont(ofSize: 12)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Сколько строк займёт текст в ширину карточки (не больше `limit`).
    static func lines(_ text: String, font: NSFont, limit: Int) -> Int {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return min(limit, max(1, Int(ceil(width / inner))))
    }
}

/// Тихая кнопка (третий уровень после «Разрешить» и «Отклонить»): мягкая подложка видна всегда, чтобы было понятно,
/// что это кнопка, а не подпись; под курсором светлеет.
struct QuietButtonStyle: ButtonStyle {
    /// Ниже и мельче — для подвала списка.
    var compact = false

    func makeBody(configuration: Configuration) -> some View { QuietButton(configuration: configuration, compact: compact) }

    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, compact ? 8 : 9).padding(.vertical, compact ? 5 : 10)
                .foregroundStyle(Color(white: hovering || pressed ? 0.95 : 0.74))
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(pressed ? 0.15 : hovering ? 0.10 : 0.055)))
                .contentShape(RoundedRectangle(cornerRadius: 11))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

struct CardView: View {
    @ObservedObject var model: IslandViewModel

    var body: some View {
        if let card = model.presenter.currentCard {
            let label = model.label(for: card.session)
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: (model.geometry?.notchHeight ?? 32) + CardMetrics.top)
                header(label, card)
                Spacer().frame(height: CardMetrics.afterHeader)
                // Что именно разрешается — словами; под этим пояснение, которое Claude сам написал к запросу.
                Text(card.request.question)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color(white: 0.94))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let purpose = card.request.purpose {
                    Text(purpose)
                        .font(.system(size: 12))
                        .foregroundStyle(Look.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, CardMetrics.purposeGap)
                }
                Spacer().frame(height: CardMetrics.beforeCode)
                ScrollView {
                    codeText(card.request)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(CardMetrics.codePad)
                .background(RoundedRectangle(cornerRadius: 12).fill(Look.codeFill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Look.codeLine))
                Spacer().frame(height: CardMetrics.beforeActions)
                // Как в диалогах macOS: справа ответ, слева действия «не сейчас». Не влезает имя приложения — короче.
                ViewThatFits(in: .horizontal) {
                    actions(card.session, open: card.session.hostApp.map { "Открыть в \($0)" } ?? "Открыть сессию")
                    actions(card.session, open: "Открыть")
                }
                .frame(height: CardMetrics.actions)
            }
            .padding(.horizontal, CardMetrics.hPad)
            .padding(.bottom, CardMetrics.bottom)
            .riseIn(0)
        }
    }

    /// Шапка: крупно имя сессии, под ним проект · ветка · приложение; справа — очередь и субагент, если есть.
    private func header(_ label: SessionLabel, _ card: (request: PermissionRequest, session: Session)) -> some View {
        let context = (label.context + [card.session.hostApp].compactMap { $0 }).joined(separator: " · ")
        let total = model.presenter.queuedBehindCurrent + 1
        return HStack(alignment: .top, spacing: 10) {
            StatusDot(status: .waitingPermission).padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(label.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .frame(height: CardMetrics.titleLine)
                if !context.isEmpty {
                    Text(context).font(.system(size: 11.5)).foregroundStyle(Look.muted).lineLimit(1)
                        .frame(height: CardMetrics.contextLine)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                if total > 1 {
                    Text("1 из \(total)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Look.muted)
                        .frame(height: CardMetrics.titleLine)
                        .accessibilityLabel("Запрос 1 из \(total)")
                }
                if let agent = card.request.agentType {
                    Text("субагент \(agent)").font(.system(size: 11.5)).foregroundStyle(Look.muted).lineLimit(1)
                        .frame(height: CardMetrics.contextLine)
                }
            }
        }
    }

    private func actions(_ session: Session, open: String) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(open) { model.jump(to: session) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Перейти к сессии и ответить там")
                Button("Позже") { model.dismissCard() }
                    .buttonStyle(QuietButtonStyle())
                    .help("Убрать карточку: запрос подождёт ответа в терминале")
            }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Button("Отклонить") { model.decide(allow: false) }
                    .buttonStyle(PillButtonStyle(kind: .neutral)).fixedSize()
                Button("Разрешить") { model.decide(allow: true) }
                    .buttonStyle(PillButtonStyle(kind: .allow)).fixedSize()
            }
        }
    }

    /// Текст запроса: команда как есть; у правки файла строки «-» и «+» подкрашены, чтобы было видно, что уходит и что приходит.
    private func codeText(_ request: PermissionRequest) -> Text {
        guard request.toolName == "Edit" || request.toolName == "MultiEdit" else {
            return Text(request.detail).foregroundColor(Look.code)
        }
        let lines = request.detail.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().reduce(Text("")) { text, item in
            let line = String(item.element)
            let color = line.hasPrefix("- ") ? Look.removed : line.hasPrefix("+ ") ? Look.added : Look.muted
            return text + Text((item.offset == 0 ? "" : "\n") + line).foregroundColor(color)
        }
    }
}

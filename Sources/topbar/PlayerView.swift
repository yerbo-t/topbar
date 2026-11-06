import AppKit
import SwiftUI
import TopbarCore

/// Плеер на острове: крупная обложка, название, исполнитель, «эквалайзер», ход трека и три кнопки. Обложка с названием —
/// кнопка: открывает приложение, откуда играет музыка.
struct PlayerView: View {
    @ObservedObject var model: IslandViewModel
    static let height: CGFloat = 164

    var body: some View {
        if let np = model.nowPlaying {
            VStack(spacing: 12) {
                OpenSourceRow(model: model, np: np)
                ProgressRow(model: model, np: np)
                HStack(spacing: 34) {
                    Spacer(minLength: 0)
                    control("backward.fill", size: 15, label: "Предыдущий") { model.mediaPrevious() }
                    control(np.playing ? "pause.fill" : "play.fill", size: 22, label: np.playing ? "Пауза" : "Играть") { model.mediaToggle() }
                    control("forward.fill", size: 15, label: "Следующий") { model.mediaNext() }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .frame(height: Self.height, alignment: .top)
        }
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 34, height: 30)
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Верх плеера: обложка, название, исполнитель и источник. Нажатие выводит вперёд приложение-источник (стрелка справа).
struct OpenSourceRow: View {
    @ObservedObject var model: IslandViewModel
    let np: NowPlaying
    @State private var hovering = false

    var body: some View {
        let source = model.mediaSourceApp
        Button { model.openMediaSource() } label: {
            HStack(spacing: 14) {
                ArtworkView(image: model.artwork, size: 68, radius: 13)
                VStack(alignment: .leading, spacing: 4) {
                    Text(np.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text([np.artist, source?.localizedName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(Look.muted).lineLimit(1)
                    EqualizerView(playing: np.playing, bars: 5).frame(width: 26, height: 14).padding(.top, 2)
                }
                Spacer(minLength: 8)
                if source != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(hovering ? Color.white : Color(white: 0.5))
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 16).fill(hovering && source != nil ? Color.white.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source == nil)
        .onHover { hovering = $0 }
        .help(source.flatMap { $0.localizedName }.map { "Открыть \($0)" } ?? "")
        .accessibilityLabel(source?.localizedName.map { "Открыть \($0)" } ?? np.title)
        .accessibilityHint("Выведет вперёд приложение, из которого играет музыка")
    }
}

struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

/// Полоса хода трека: тянется пальцем/мышью — перематывает. Идёт сама раз в секунду, пока играет.
struct ProgressRow: View {
    let model: IslandViewModel
    let np: NowPlaying
    @State private var dragFraction: Double?

    var body: some View {
        if let duration = np.duration {
            TimelineView(.periodic(from: .now, by: np.playing ? 1 : 3600)) { context in
                let position = dragFraction.map { $0 * duration } ?? np.position(at: context.date) ?? 0
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(white: 0.22))
                            Capsule().fill(Color.white).frame(width: max(4, geo.size.width * CGFloat(min(1, position / duration))))
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = fraction($0.location.x, geo.size.width) }
                            .onEnded { value in
                                let f = fraction(value.location.x, geo.size.width)
                                dragFraction = nil
                                model.mediaSeek(to: f * duration)
                            })
                    }
                    .frame(height: 4)
                    HStack {
                        Text(Self.format(position))
                        Spacer()
                        Text(Self.format(duration))
                    }
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.58))
                }
            }
        }
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double { Double(min(max(x / max(width, 1), 0), 1)) }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.16)
                    Image(systemName: "music.note").font(.system(size: size * 0.42)).foregroundStyle(Color(white: 0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .accessibilityHidden(true)
    }
}

/// Три полоски «эквалайзера»; анимацию рисует Core Animation (в приложении она ничего не стоит). На паузе и при
/// «уменьшении движения» полоски стоят.
struct EqualizerView: NSViewRepresentable {
    let playing: Bool
    var bars = 3

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView(bars: bars) }
    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.setPlaying(playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class EqualizerNSView: NSView {
    private var bars: [CALayer] = []
    private var isAnimating = false

    init(bars count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
            bar.position = CGPoint(x: 1.5 + CGFloat(i) * 5.5, y: 0)
        }
    }

    func setPlaying(_ on: Bool) {
        guard on != isAnimating else { return }
        isAnimating = on
        for (i, bar) in bars.enumerated() {
            if on {
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = 0.25
                animation.toValue = 1.0
                animation.duration = 0.42 + 0.13 * Double(i % 4)
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(animation, forKey: "eq")
            } else {
                bar.removeAnimation(forKey: "eq")
            }
        }
    }
}

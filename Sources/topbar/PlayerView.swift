import AppKit
import SwiftUI
import TopbarCore

/// Плеер на острове: обложка, название, исполнитель, ход трека и три кнопки.
struct PlayerView: View {
    @ObservedObject var model: IslandViewModel
    static let height: CGFloat = 146

    var body: some View {
        if let np = model.nowPlaying {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkView(image: model.artwork, size: 54, radius: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(np.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Text(subtitle(np)).font(.system(size: 12)).foregroundStyle(Color(white: 0.66)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    EqualizerView(playing: np.playing).frame(width: 16, height: 14)
                }
                ProgressRow(model: model, np: np)
                HStack(spacing: 34) {
                    Spacer(minLength: 0)
                    control("backward.fill", size: 15, label: "Предыдущий") { model.mediaPrevious() }
                    control(np.playing ? "pause.fill" : "play.fill", size: 22, label: np.playing ? "Пауза" : "Играть") { model.mediaToggle() }
                    control("forward.fill", size: 15, label: "Следующий") { model.mediaNext() }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(height: Self.height, alignment: .top)
        }
    }

    private func subtitle(_ np: NowPlaying) -> String {
        [np.artist, model.mediaSourceName].compactMap { $0 }.joined(separator: " · ")
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 34, height: 30)
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(label)
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

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }
    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.setPlaying(playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class EqualizerNSView: NSView {
    private var bars: [CALayer] = []
    private var isAnimating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<3 {
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
                animation.duration = 0.42 + 0.13 * Double(i)
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

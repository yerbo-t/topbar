import AppKit
import SwiftUI

/// Вид «как в демо на сайте»: цвета, кнопки и появление строк. Значения взяты из страницы `server/public/index.html`.
enum Look {
    static let allow = Color(red: 0.275, green: 0.780, blue: 0.467)          // #46c777
    static let allowPressed = Color(red: 0.373, green: 0.878, blue: 0.557)   // #5fe08e
    static let allowInk = Color(red: 0.016, green: 0.129, blue: 0.059)       // #04210f
    static let neutralFill = Color(red: 0.102, green: 0.106, blue: 0.129)    // #1a1b21
    static let neutralLine = Color(red: 0.204, green: 0.212, blue: 0.259)    // #343642
    static let codeFill = Color(red: 0.067, green: 0.071, blue: 0.094)       // #111218
    static let codeLine = Color(red: 0.137, green: 0.145, blue: 0.176)       // #23252d
    static let code = Color(red: 0.863, green: 0.867, blue: 0.886)           // #dcdde2
    static let tool = Color(red: 0.478, green: 0.635, blue: 1.0)             // #7aa2ff
    static let muted = Color(red: 0.663, green: 0.671, blue: 0.710)          // #a9abb5
    /// Подсветка строки, которой нужно внимание.
    static let hot = Color.white.opacity(0.08)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Подпись сессии «проект · ветка»: проект крупно, ветка рядом спокойным цветом (как в демо на сайте).
func sessionTitle(_ title: String, size: CGFloat) -> Text {
    guard let range = title.range(of: " · ") else { return Text(title).font(.system(size: size, weight: .semibold)) }
    return Text(title[..<range.lowerBound]).font(.system(size: size, weight: .semibold))
        + Text(" · " + String(title[range.upperBound...])).font(.system(size: size - 2)).foregroundColor(Look.muted)
}

/// Кнопка-таблетка: зелёная «Разрешить», тёмная с тонкой рамкой «Отклонить», светлая для крупных действий. При нажатии
/// чуть сжимается (при «Уменьшить движение» — без сжатия).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case allow, neutral, light }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let ink: Color = switch kind {
        case .allow: Look.allowInk
        case .neutral: .white
        case .light: .black
        }
        let fill: Color = switch kind {
        case .allow: pressed ? Look.allowPressed : Look.allow
        case .neutral: Look.neutralFill
        case .light: Color(white: pressed ? 1.0 : 0.92)
        }
        let line: Color = kind == .neutral ? Look.neutralLine : .clear
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .foregroundStyle(ink)
            .background(RoundedRectangle(cornerRadius: 12).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(line, lineWidth: 1))
            .scaleEffect(pressed && !Look.reduceMotion ? 0.93 : 1)
            .animation(.easeOut(duration: 0.18), value: pressed)
    }
}

/// Строка появляется после раскрытия острова: чуть снизу и из прозрачности, каждая следующая позже предыдущей.
struct RiseIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || Look.reduceMotion ? 1 : 0)
            .offset(y: shown || Look.reduceMotion ? 0 : 9)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.16 + 0.07 * Double(min(index, 6)))) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }
}

import AppKit
import SwiftUI
import TopbarCore

/// Размеры карточки с вопросом Claude: по ним и рисуется вид, и считается высота острова.
enum QuestionMetrics {
    static let tagLine: CGFloat = 15
    static let beforeOptions: CGFloat = 10
    static let optionGap: CGFloat = 6
    static let optionPadV: CGFloat = 10
    static let optionPadH: CGFloat = 14
    static let labelLine: CGFloat = 17
    static let detailLine: CGFloat = 15
    static let markWidth: CGFloat = 26

    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 11.5)

    /// Метка над вопросом: «Цвет · 1 из 2»; пусто — метка не нужна.
    static func tag(_ question: AskQuestion, index: Int, count: Int) -> String {
        [question.header, count > 1 ? "\(index + 1) из \(count)" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    static func lines(_ text: String, font: NSFont, width: CGFloat, limit: Int) -> Int {
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return min(limit, max(1, Int(ceil(measured / max(1, width)))))
    }

    static func textWidth(multi: Bool) -> CGFloat { CardMetrics.inner - 2 * optionPadH - (multi ? markWidth : 0) }

    static func optionHeight(_ option: AskOption, multi: Bool) -> CGFloat {
        let detailLines = option.detail.map { lines($0, font: detailFont, width: textWidth(multi: multi), limit: 2) } ?? 0
        return 2 * optionPadV + labelLine + CGFloat(detailLines) * detailLine
    }

    /// Высота всего, что между шапкой и кнопками внизу: метка, вопрос, варианты.
    static let noticeLine: CGFloat = 15
    static let noticeGap: CGFloat = 8

    static func bodyHeight(_ question: AskQuestion, index: Int, count: Int, notice: Bool = false) -> CGFloat {
        let tag = tag(question, index: index, count: count).isEmpty ? 0 : tagLine
        let text = CGFloat(lines(question.question, font: CardMetrics.questionFont, width: CardMetrics.inner, limit: 3)) * CardMetrics.questionLine
        let options = question.options.map { optionHeight($0, multi: question.multiSelect) }
        let noticeHeight = notice ? noticeGap + noticeLine : 0
        return tag + text + beforeOptions + options.reduce(0, +) + optionGap * CGFloat(max(0, options.count - 1)) + noticeHeight
    }
}

extension CardView {
    /// Карточка с вопросом Claude: варианты кнопками. Один ответ — нажатие сразу отвечает (на последнем вопросе) или ведёт к следующему;
    /// несколько ответов — отметить и нажать «Далее» / «Готово».
    @ViewBuilder
    func questionBody(_ card: (request: PermissionRequest, session: Session), questions: [AskQuestion]) -> some View {
        let index = min(model.ask.index, questions.count - 1)
        let question = questions[index]
        let label = model.label(for: card.session)
        let tag = QuestionMetrics.tag(question, index: index, count: questions.count)
        let chosen = model.ask.picks[question.question] ?? []
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: (model.geometry?.notchHeight ?? 32) + CardMetrics.top)
            header(label, card)
            Spacer().frame(height: CardMetrics.afterHeader)
            if !tag.isEmpty {
                Text(tag).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Look.muted).lineLimit(1)
                    .frame(height: QuestionMetrics.tagLine, alignment: .leading)
            }
            Text(question.question)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color(white: 0.94))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: QuestionMetrics.beforeOptions)
            VStack(spacing: QuestionMetrics.optionGap) {
                ForEach(question.options, id: \.label) { option in
                    AskOptionRow(option: option, multi: question.multiSelect, selected: chosen.contains(option.label)) {
                        model.askPick(option.label)
                    }
                }
            }
            if let notice = model.ask.notice {
                Text(notice)
                    .font(.system(size: 11.5)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25)).lineLimit(1)
                    .frame(height: QuestionMetrics.noticeLine, alignment: .leading)
                    .padding(.top, QuestionMetrics.noticeGap)
            }
            Spacer().frame(height: CardMetrics.beforeActions)
            ViewThatFits(in: .horizontal) {
                questionActions(card.session, question: question, index: index, count: questions.count, chosen: chosen,
                                open: card.session.hostApp.map { "Открыть в \($0)" } ?? "Открыть сессию")
                questionActions(card.session, question: question, index: index, count: questions.count, chosen: chosen, open: "Открыть")
            }
            .frame(height: CardMetrics.actions)
        }
        .padding(.horizontal, CardMetrics.hPad)
        .padding(.bottom, CardMetrics.bottom)
        .riseIn(0)
    }

    private func questionActions(_ session: Session, question: AskQuestion, index: Int, count: Int, chosen: [String], open: String) -> some View {
        let last = index == count - 1
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if index > 0 {
                    Button("Назад") { model.askBack() }
                        .buttonStyle(QuietButtonStyle())
                        .help("Вернуться к предыдущему вопросу")
                }
                Button(open) { model.jump(to: session) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Перейти к сессии и ответить там")
                Button("Позже") { model.dismissCard() }
                    .buttonStyle(QuietButtonStyle())
                    .help("Убрать карточку: вопрос подождёт ответа в терминале")
            }
            Spacer(minLength: 10)
            if question.multiSelect {
                Button(last ? "Готово" : "Далее") { model.askNext() }
                    .buttonStyle(PillButtonStyle(kind: .allow)).fixedSize()
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.45 : 1)
                    .help(chosen.isEmpty ? "Отметьте хотя бы один вариант" : (last ? "Отправить ответ Claude" : "К следующему вопросу"))
            }
        }
    }
}

/// Вариант ответа кнопкой: подпись, мелкое пояснение; у вопроса с несколькими ответами — флажок.
struct AskOptionRow: View {
    let option: AskOption
    let multi: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                if multi {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Look.allow : Look.muted)
                        .frame(width: QuestionMetrics.markWidth - 10, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .frame(height: QuestionMetrics.labelLine, alignment: .leading)
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Look.muted).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, QuestionMetrics.optionPadH).padding(.vertical, QuestionMetrics.optionPadV)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(AskOptionButtonStyle(selected: selected))
        .accessibilityLabel(option.label + (option.detail.map { ". " + $0 } ?? ""))
        .accessibilityHint(multi ? (selected ? "Снять отметку" : "Отметить вариант") : "Ответить Claude этим вариантом")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AskOptionButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View { OptionBody(configuration: configuration, selected: selected) }

    private struct OptionBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(Color(white: 0.95))
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(pressed ? 0.17 : hovering ? 0.12 : selected ? 0.10 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Look.allow.opacity(0.7) : Look.neutralLine.opacity(0.6), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

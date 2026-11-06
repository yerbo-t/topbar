import Foundation

/// Вариант ответа на вопрос Claude.
public struct AskOption: Equatable, Sendable {
    public let label: String
    /// Пояснение к варианту (мелким шрифтом под названием).
    public let detail: String?
}

/// Один вопрос из `AskUserQuestion`.
public struct AskQuestion: Equatable, Sendable {
    public let question: String
    /// Короткая метка вопроса («Цвет», «Заголовок»).
    public let header: String?
    public let multiSelect: Bool
    public let options: [AskOption]
}

/// Вопросы Claude, которые остров умеет показать и на которые умеет ответить. Всё остальное (картинки-превью у вариантов,
/// нетипичное число вопросов и вариантов, повторы) остаётся диалогом в терминале.
public enum AskQuestions {
    static let maxQuestions = 4
    static let maxOptions = 4

    /// Разобрать `tool_input` вызова `AskUserQuestion`. nil — форма не та, остров вопрос не берёт.
    public static func parse(_ input: JSONValue?) -> [AskQuestion]? {
        guard case .array(let items)? = input?["questions"], (1...maxQuestions).contains(items.count) else { return nil }
        var result: [AskQuestion] = []
        for item in items {
            guard let text = item["question"]?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  case .array(let rawOptions)? = item["options"], (2...maxOptions).contains(rawOptions.count) else { return nil }
            var options: [AskOption] = []
            for raw in rawOptions {
                // Превью (картинка или текст рядом с вариантом) на острове не нарисовать.
                if let preview = raw["preview"], preview != .null { return nil }
                guard let label = raw["label"]?.stringValue, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let detail = raw["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                options.append(AskOption(label: label, detail: detail))
            }
            // Ответ ищется по тексту вопроса и подписи варианта: повторы сделали бы его двусмысленным.
            guard Set(options.map(\.label)).count == options.count else { return nil }
            var multi = false
            if case .bool(let flag)? = item["multiSelect"] { multi = flag }
            let header = item["header"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            result.append(AskQuestion(question: text, header: header, multiSelect: multi, options: options))
        }
        guard Set(result.map(\.question)).count == result.count else { return nil }
        return result
    }

    /// Ответы для Claude Code из выбора владельца (вопрос → выбранные подписи). nil — выбор не подходит к вопросам:
    /// чужой вопрос или вариант, пустой выбор, несколько вариантов у вопроса с одним ответом. Несколько вариантов склеиваются
    /// через «, » в порядке списка вариантов (так Claude Code принимает множественный выбор; проверено опытом).
    public static func answers(from picks: [String: [String]], for questions: [AskQuestion]) -> [String: String]? {
        guard Set(picks.keys) == Set(questions.map(\.question)) else { return nil }
        var result: [String: String] = [:]
        for question in questions {
            let chosen = Set(picks[question.question] ?? [])
            let known = Set(question.options.map(\.label))
            guard !chosen.isEmpty, chosen.isSubset(of: known), question.multiSelect || chosen.count == 1 else { return nil }
            result[question.question] = question.options.map(\.label).filter(chosen.contains).joined(separator: ", ")
        }
        return result
    }
}

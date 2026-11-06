import XCTest
@testable import TopbarCore

final class AskQuestionTests: XCTestCase {
    static func option(_ label: String, _ detail: String? = nil, preview: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["label": .string(label)]
        if let detail { o["description"] = .string(detail) }
        if let preview { o["preview"] = .string(preview) }
        return .object(o)
    }

    static func question(_ text: String = "Какой цвет?", header: String? = "Цвет", multi: Bool? = nil,
                         options: [JSONValue]? = nil) -> JSONValue {
        var q: [String: JSONValue] = ["question": .string(text),
                                      "options": .array(options ?? [option("Красный", "Тёплый"), option("Синий")])]
        if let header { q["header"] = .string(header) }
        if let multi { q["multiSelect"] = .bool(multi) }
        return .object(q)
    }

    static func input(_ questions: [JSONValue]) -> JSONValue { .object(["questions": .array(questions)]) }

    // MARK: разбор

    func testParsesQuestionWithOptions() throws {
        let parsed = try XCTUnwrap(AskQuestions.parse(Self.input([Self.question()])))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].question, "Какой цвет?")
        XCTAssertEqual(parsed[0].header, "Цвет")
        XCTAssertFalse(parsed[0].multiSelect)
        XCTAssertEqual(parsed[0].options, [AskOption(label: "Красный", detail: "Тёплый"), AskOption(label: "Синий", detail: nil)])
    }

    func testMultiSelectAndSeveralQuestions() throws {
        let parsed = try XCTUnwrap(AskQuestions.parse(Self.input([Self.question("А?", multi: true), Self.question("Б?")])))
        XCTAssertEqual(parsed.map(\.multiSelect), [true, false])
    }

    func testShapesTheIslandCannotShowAreNotParsed() {
        let tooMany = (1...5).map { Self.option("v\($0)") }
        let cases: [(String, JSONValue?)] = [
            ("нет ввода", nil),
            ("нет вопросов", .object([:])),
            ("пустой список", Self.input([])),
            ("пять вопросов", Self.input((1...5).map { Self.question("Вопрос \($0)?") })),
            ("один вариант", Self.input([Self.question(options: [Self.option("Один")])])),
            ("пять вариантов", Self.input([Self.question(options: tooMany)])),
            ("превью у варианта", Self.input([Self.question(options: [Self.option("А", preview: "x"), Self.option("Б")])])),
            ("повтор вопроса", Self.input([Self.question("Так?"), Self.question("Так?")])),
            ("повтор варианта", Self.input([Self.question(options: [Self.option("А"), Self.option("А")])])),
            ("пустая подпись", Self.input([Self.question(options: [Self.option(" "), Self.option("Б")])])),
            ("пустой вопрос", Self.input([Self.question("  ")])),
        ]
        for (name, input) in cases { XCTAssertNil(AskQuestions.parse(input), name) }
    }

    func testNullPreviewIsTreatedAsAbsent() {
        let option: JSONValue = .object(["label": .string("А"), "preview": .null])
        XCTAssertNotNil(AskQuestions.parse(Self.input([Self.question(options: [option, Self.option("Б")])])))
    }

    // MARK: ответы

    func testSingleAnswerIsTheLabel() throws {
        let questions = try XCTUnwrap(AskQuestions.parse(Self.input([Self.question()])))
        XCTAssertEqual(AskQuestions.answers(from: ["Какой цвет?": ["Синий"]], for: questions), ["Какой цвет?": "Синий"])
    }

    func testMultiAnswerIsJoinedInOptionOrder() throws {
        let options = ["Красный", "Синий", "Зелёный"].map { Self.option($0) }
        let questions = try XCTUnwrap(AskQuestions.parse(Self.input([Self.question("Цвета?", multi: true, options: options)])))
        XCTAssertEqual(AskQuestions.answers(from: ["Цвета?": ["Зелёный", "Красный"]], for: questions), ["Цвета?": "Красный, Зелёный"])
    }

    func testSeveralQuestionsNeedAnAnswerEach() throws {
        let questions = try XCTUnwrap(AskQuestions.parse(Self.input([Self.question("А?"), Self.question("Б?")])))
        XCTAssertNil(AskQuestions.answers(from: ["А?": ["Синий"]], for: questions))
        XCTAssertEqual(AskQuestions.answers(from: ["А?": ["Синий"], "Б?": ["Красный"]], for: questions)?.count, 2)
    }

    func testInvalidPicksAreRejected() throws {
        let questions = try XCTUnwrap(AskQuestions.parse(Self.input([Self.question()])))
        XCTAssertNil(AskQuestions.answers(from: ["Какой цвет?": ["Жёлтый"]], for: questions), "неизвестный вариант")
        XCTAssertNil(AskQuestions.answers(from: ["Какой цвет?": []], for: questions), "пустой выбор")
        XCTAssertNil(AskQuestions.answers(from: ["Какой цвет?": ["Красный", "Синий"]], for: questions), "два ответа на вопрос с одним")
        XCTAssertNil(AskQuestions.answers(from: ["Другой вопрос?": ["Красный"]], for: questions), "чужой вопрос")
        XCTAssertNil(AskQuestions.answers(from: ["Какой цвет?": ["Красный"], "Лишний?": ["Да"]], for: questions), "лишний вопрос")
    }

    // MARK: подпись в списке

    func testListShowsWhatTheSessionIsDoingForQuestionTools() {
        XCTAssertEqual(ActionDescriber.describe(toolName: "AskUserQuestion", input: nil), "Задаёт вопрос")
        XCTAssertEqual(ActionDescriber.describe(toolName: "ExitPlanMode", input: nil), "Ждёт решения по плану")
        XCTAssertEqual(ActionDescriber.describe(toolName: "Glob", input: nil), "Glob", "прочие инструменты — по имени, как раньше")
    }
}

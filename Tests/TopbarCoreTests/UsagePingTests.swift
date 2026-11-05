import XCTest
@testable import TopbarCore

final class UsagePingTests: XCTestCase {
    func testNameIsTrimmedCappedAndEmptyMeansNone() {
        XCTAssertNil(UsagePing.cleanName(nil))
        XCTAssertNil(UsagePing.cleanName("   \n"))
        XCTAssertEqual(UsagePing.cleanName("  Анна  "), "Анна")
        XCTAssertEqual(UsagePing.cleanName(String(repeating: "я", count: 200))?.count, 60)
    }

    func testSendsFirstTimeOnNewVersionAndDaily() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UsagePing.shouldSend(lastSentAt: nil, lastVersion: nil, version: "1.0", now: now))
        XCTAssertFalse(UsagePing.shouldSend(lastSentAt: now.addingTimeInterval(-3600), lastVersion: "1.0", version: "1.0", now: now))
        XCTAssertTrue(UsagePing.shouldSend(lastSentAt: now.addingTimeInterval(-3600), lastVersion: "1.0", version: "1.1", now: now), "новая версия — сообщаем сразу")
        XCTAssertTrue(UsagePing.shouldSend(lastSentAt: now.addingTimeInterval(-25 * 3600), lastVersion: "1.0", version: "1.0", now: now))
    }

    func testEventIsInstallOnlyForTheFirstMessage() {
        XCTAssertEqual(UsagePing.event(lastSentAt: nil), "install")
        XCTAssertEqual(UsagePing.event(lastSentAt: Date()), "launch")
    }

    func testPayloadContainsOnlyTheDeclaredFields() throws {
        let ping = UsagePing(id: "A", name: "Анна", version: "0.2.0", build: "32", macos: "26.6.2", event: "install")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ping)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["id", "name", "version", "build", "macos", "event"])
        XCTAssertTrue(ping.jsonString().contains("\"name\" : \"Анна\""))
    }
}

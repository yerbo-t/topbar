import XCTest
@testable import TopbarCore

final class NowPlayingTests: XCTestCase {
    func testParsesStateWithArtwork() throws {
        let line = #"{"title":"Трек","artist":"Артист","album":"","playing":true,"duration":200,"elapsed":10,"rate":1,"timestamp":1000,"pid":42,"artwork":"AQID"}"#
        guard case let .state(np, art)? = NowPlayingMessage.parse(line) else { return XCTFail("не разобралось") }
        XCTAssertEqual(np.title, "Трек")
        XCTAssertEqual(np.artist, "Артист")
        XCTAssertNil(np.album, "пустая строка — нет значения")
        XCTAssertTrue(np.playing)
        XCTAssertEqual(np.pid, 42)
        XCTAssertEqual(art, .data(Data([1, 2, 3])))
    }

    func testArtworkAbsentMeansUnchangedAndNullMeansCleared() {
        guard case let .state(_, a1)? = NowPlayingMessage.parse(#"{"title":"T","playing":false}"#) else { return XCTFail() }
        XCTAssertEqual(a1, .unchanged)
        guard case let .state(_, a2)? = NowPlayingMessage.parse(#"{"title":"T","playing":false,"artwork":null}"#) else { return XCTFail() }
        XCTAssertEqual(a2, .cleared)
    }

    func testNothingAndFailureAndGarbage() {
        XCTAssertEqual(NowPlayingMessage.parse(#"{"none":true}"#), .nothing(.unchanged))
        XCTAssertEqual(NowPlayingMessage.parse(#"{"error":"MediaRemote не загрузился"}"#), .failure("MediaRemote не загрузился"))
        XCTAssertNil(NowPlayingMessage.parse("не json"))
        XCTAssertNil(NowPlayingMessage.parse(#"{"playing":true}"#), "без названия — не состояние")
    }

    func testPositionAdvancesWhilePlayingOnly() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let playing = NowPlaying(title: "T", playing: true, duration: 100, elapsed: 10, rate: 1, timestamp: t0)
        XCTAssertEqual(playing.position(at: t0.addingTimeInterval(5)), 15)
        var paused = playing; paused.playing = false
        XCTAssertEqual(paused.position(at: t0.addingTimeInterval(5)), 10, "на паузе не идёт")
        XCTAssertEqual(playing.position(at: t0.addingTimeInterval(500)), 100, "не дальше длительности")
        XCTAssertNil(NowPlaying(title: "T", playing: true).position(at: t0))
        var fast = playing; fast.rate = 2
        XCTAssertEqual(fast.position(at: t0.addingTimeInterval(5)), 20)
    }

    func testCommandsMapToMediaRemoteNumbers() {
        XCTAssertEqual(NowPlayingCommand.toggle.environment, ["TB_COMMAND": "2"])
        XCTAssertEqual(NowPlayingCommand.next.environment, ["TB_COMMAND": "4"])
        XCTAssertEqual(NowPlayingCommand.previous.environment, ["TB_COMMAND": "5"])
        XCTAssertEqual(NowPlayingCommand.seek(12.5).environment, ["TB_SEEK": "12.50"])
    }

    func testVisibilityGraceAfterPause() {
        let now = Date(timeIntervalSince1970: 5000)
        let playing = NowPlaying(title: "T", playing: true)
        let paused = NowPlaying(title: "T", playing: false)
        XCTAssertTrue(MediaVisibility.isVisible(playing, pausedSince: nil, now: now))
        XCTAssertTrue(MediaVisibility.isVisible(paused, pausedSince: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(MediaVisibility.isVisible(paused, pausedSince: now.addingTimeInterval(-60), now: now), "на паузе дольше 45 с — прячем")
        XCTAssertFalse(MediaVisibility.isVisible(nil, pausedSince: nil, now: now))
    }

    func testIslandShowsWithMediaOnlyAndHidesWhenItStops() {
        var p = IslandPresenter()
        XCTAssertEqual(p.mode, .hidden)
        p.setMedia(active: true)
        XCTAssertEqual(p.mode, .collapsed)
        p.setList(open: true)
        XCTAssertEqual(p.mode, .list, "плеер открывается и без сессий")
        p.setMedia(active: false)
        XCTAssertEqual(p.mode, .hidden)
        XCTAssertFalse(p.listOpen)
    }
}

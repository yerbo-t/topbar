import Foundation

/// Что сейчас играет в системе (из помощника `native/nowplaying.m`).
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var playing: Bool
    public var duration: Double?
    public var elapsed: Double?
    public var rate: Double
    public var timestamp: Date?
    public var pid: Int?

    public init(title: String, artist: String? = nil, album: String? = nil, playing: Bool, duration: Double? = nil,
                elapsed: Double? = nil, rate: Double = 1, timestamp: Date? = nil, pid: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.playing = playing
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.timestamp = timestamp
        self.pid = pid
    }

    /// Положение в треке на момент `date`: система сообщает отсчёт и время, когда он был снят, дальше считаем сами.
    public func position(at date: Date) -> Double? {
        guard let elapsed else { return nil }
        var value = elapsed
        if playing, let timestamp { value += max(0, date.timeIntervalSince(timestamp)) * (rate > 0 ? rate : 1) }
        if let duration, duration > 0 { value = min(value, duration) }
        return max(0, value)
    }
}

/// Обложка в сообщении помощника: приходит только когда поменялась.
public enum ArtworkUpdate: Equatable, Sendable {
    case unchanged
    case cleared
    case data(Data)
}

/// Строка потока помощника.
public enum NowPlayingMessage: Equatable, Sendable {
    case state(NowPlaying, ArtworkUpdate)
    case nothing(ArtworkUpdate)       // ничего не играет
    case failure(String)              // помощник не смог (Apple закрыла приём)

    public static func parse(_ line: String) -> NowPlayingMessage? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? String { return .failure(error) }
        let art: ArtworkUpdate
        if let encoded = object["artwork"] as? String, let bytes = Data(base64Encoded: encoded) {
            art = .data(bytes)
        } else if object["artwork"] is NSNull {
            art = .cleared
        } else {
            art = .unchanged
        }
        if object["none"] as? Bool == true { return .nothing(art) }
        guard let title = object["title"] as? String else { return nil }
        let state = NowPlaying(
            title: title,
            artist: (object["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: (object["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            playing: object["playing"] as? Bool ?? false,
            duration: (object["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            elapsed: object["elapsed"] as? Double,
            rate: object["rate"] as? Double ?? 1,
            timestamp: (object["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) },
            pid: object["pid"] as? Int)
        return .state(state, art)
    }
}

/// Команды плееру (номера — как у MediaRemote).
public enum NowPlayingCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous
    case seek(Double)

    public var environment: [String: String] {
        switch self {
        case .play: return ["TB_COMMAND": "0"]
        case .pause: return ["TB_COMMAND": "1"]
        case .toggle: return ["TB_COMMAND": "2"]
        case .next: return ["TB_COMMAND": "4"]
        case .previous: return ["TB_COMMAND": "5"]
        case .seek(let seconds): return ["TB_SEEK": String(format: "%.2f", seconds)]
        }
    }
}

/// Решает, показывать ли плеер на острове: играет — да; на паузе — ещё `pauseGrace` секунд, потом прячем.
public struct MediaVisibility: Sendable {
    public static let pauseGrace: TimeInterval = 45

    public static func isVisible(_ nowPlaying: NowPlaying?, pausedSince: Date?, now: Date) -> Bool {
        guard let nowPlaying else { return false }
        if nowPlaying.playing { return true }
        guard let pausedSince else { return true }
        return now.timeIntervalSince(pausedSince) < pauseGrace
    }
}

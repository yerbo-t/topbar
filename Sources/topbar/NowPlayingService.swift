import AppKit
import TopbarCore

/// Накопитель байтов из канала помощника; обработчик чтения вызывается по очереди, поэтому доступ не пересекается.
private final class LineBuffer: @unchecked Sendable { var data = Data() }

/// Запускает помощника «Сейчас играет» (системный perl с нашей библиотекой внутри, см. `native/nowplaying.m`), читает его
/// поток состояний и отправляет команды плееру. Если помощник не заводится три раза подряд (Apple закрыла приём) —
/// сообщает `onUnavailable`, и плеер просто не показывается.
@MainActor
final class NowPlayingService {
    var onMessage: ((NowPlayingMessage) -> Void)?
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var stopped = true
    private var failures = 0
    private var startedAt = Date.distantPast
    private var restartWork: DispatchWorkItem?

    /// Perl грузит библиотеку и вызывает одну функцию из неё (имя — второй параметр).
    private static let loader = """
        use DynaLoader; my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die "load failed"; \
        my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die "symbol missing"; \
        DynaLoader::dl_install_xsub("main::tb", $s); &{"main::tb"}();
        """

    static var libraryPath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("libtbnowplaying.dylib").path,
            ProcessInfo.processInfo.environment["TB_NOWPLAYING_LIB"],
            FileManager.default.currentDirectoryPath + "/build/libtbnowplaying.dylib",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() {
        guard stopped, let library = Self.libraryPath else {
            if Self.libraryPath == nil { onUnavailable?() }
            return
        }
        stopped = false
        launch(library: library)
    }

    func stop() {
        stopped = true
        restartWork?.cancel()
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    /// Одна команда плееру: отдельный короткий процесс.
    func send(_ command: NowPlayingCommand) {
        guard let library = Self.libraryPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", Self.loader, library, "tb_now_playing_send"]
            p.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: внутреннее

    private func launch(library: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, library, "tb_now_playing_stream"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            buffer.data.append(chunk)
            while let newline = buffer.data.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer.data[buffer.data.startIndex..<newline], as: UTF8.self)
                buffer.data.removeSubrange(buffer.data.startIndex...newline)
                guard let message = NowPlayingMessage.parse(line) else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(message) } }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(library: library) } }
        }
        do {
            startedAt = Date()
            try p.run()
            process = p
        } catch {
            exited(library: library)
        }
    }

    private func received(_ message: NowPlayingMessage) {
        if case .failure = message {
            stop()
            onUnavailable?()
            return
        }
        failures = 0
        onMessage?(message)
    }

    private func exited(library: String) {
        process = nil
        guard !stopped else { return }
        // Мгновенный выход — помощник не заводится; несколько раз подряд — сдаёмся.
        failures = Date().timeIntervalSince(startedAt) < 3 ? failures + 1 : 0
        if failures >= 3 {
            stopped = true
            onUnavailable?()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.launch(library: library)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * Double(max(1, failures)), execute: work)
    }
}

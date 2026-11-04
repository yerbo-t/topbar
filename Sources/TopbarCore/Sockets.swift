import Foundation
import Darwin

public enum SocketError: Error, Equatable { case pathTooLong, alreadyRunning, system(String) }

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else { throw SocketError.pathTooLong }
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
    }
    return addr
}

private func withSockaddr<R>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func setNoSigPipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

// MARK: - клиент (мост)

public enum SocketClient {
    /// Подключение с тайм-аутом. nil — сокета нет, приложение не слушает или не успело принять.
    /// Соединение остаётся неблокирующим: все чтения и записи идут через `poll` с дедлайном.
    public static func connect(path: String, timeout: Double) -> Int32? {
        guard var addr = try? makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setNoSigPipe(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withSockaddr(&addr) { Darwin.connect(fd, $0, $1) }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(max(0, timeout) * 1000)) > 0 else { close(fd); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { close(fd); return nil }
        }
        return fd
    }

    /// Записать всё до дедлайна. false — не успели (получатель завис) или соединение разорвано.
    public static func writeAll(_ fd: Int32, _ data: Data, deadline: Date = Date().addingTimeInterval(1)) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buf -> Bool in
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            }
            return true
        }
    }

    /// Читает одну строку (без перевода строки). nil — тайм-аут или соединение закрыто до конца строки.
    public static func readLine(_ fd: Int32, timeout: Double) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { return nil }
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { return nil }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return nil
            }
            if byte == 0x0A { return line }
            line.append(byte)
        }
    }
}

// MARK: - сервер (ядро)

public final class ReplyChannel {
    fileprivate let fd: Int32
    private var closed = false
    /// Вызывается, когда мост закрыл соединение.
    public var onClose: (() -> Void)?

    fileprivate init(fd: Int32) { self.fd = fd }

    /// true — ответ записан в соединение (получатель мог уже закрыться, но запись не упала).
    @discardableResult
    public func send(_ reply: CoreReply) -> Bool {
        guard !closed, let data = try? Wire.encode(reply) else { return false }
        return SocketClient.writeAll(fd, data)
    }

    fileprivate func markClosed() {
        guard !closed else { return }
        closed = true
        onClose?()
    }
}

public final class SocketServer {
    public typealias Handler = (BridgeMessage, ReplyChannel) -> Void

    private let path: String
    private let queue: DispatchQueue
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var ownedInode: UInt64?
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private let maxMessageBytes = 8 * 1024 * 1024

    private final class Connection {
        let fd: Int32
        let channel: ReplyChannel
        var buffer = Data()
        var delivered = false
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd; self.channel = ReplyChannel(fd: fd) }
    }

    /// Все обработчики и колбэки каналов вызываются на `queue`.
    public init(path: String, queue: DispatchQueue, handler: @escaping Handler) {
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700) // каталог мог уже существовать с другими правами
        // Живой слушатель на этом пути — не перехватываем его сокет.
        if let probe = SocketClient.connect(path: path, timeout: 0.2) {
            close(probe)
            throw SocketError.alreadyRunning
        }
        unlink(path)
        var addr = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket: \(errno)") }
        guard withSockaddr(&addr, { Darwin.bind(fd, $0, $1) }) == 0 else {
            close(fd); throw SocketError.system("bind: \(errno)")
        }
        chmod(path, 0o600)
        var st = stat()
        if stat(path, &st) == 0 { ownedInode = UInt64(st.st_ino) }
        guard listen(fd, 32) == 0 else { close(fd); throw SocketError.system("listen: \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            for c in connections.values { finish(c) }
            // Удаляем только свой файл: если путь уже занял другой экземпляр, его сокет не трогаем.
            var st = stat()
            if let owned = ownedInode, stat(path, &st) == 0, UInt64(st.st_ino) == owned { unlink(path) }
            ownedInode = nil
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Разговаривать с сокетом должен только владелец той же учётной записи.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); continue }
            setNoSigPipe(fd)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let conn = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, unowned conn] in self?.readable(conn) }
            conn.source = source
            connections[fd] = conn
            source.resume()
        }
    }

    private func readable(_ conn: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(conn.fd, &chunk, chunk.count)
            if n > 0 {
                if !conn.delivered {
                    conn.buffer.append(chunk, count: n)
                    if conn.buffer.count > maxMessageBytes { finish(conn); return }
                    deliverIfComplete(conn)
                }
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            finish(conn) // EOF или ошибка
            return
        }
    }

    private func deliverIfComplete(_ conn: Connection) {
        guard let nl = conn.buffer.firstIndex(of: 0x0A) else { return }
        let line = conn.buffer.prefix(upTo: nl)
        conn.delivered = true
        conn.buffer = Data()
        guard let msg = try? Wire.decode(BridgeMessage.self, line: Data(line)) else { finish(conn); return }
        handler(msg, conn.channel)
    }

    private func finish(_ conn: Connection) {
        guard connections[conn.fd] != nil else { return }
        connections[conn.fd] = nil
        conn.source?.cancel()
        conn.source = nil
        conn.channel.markClosed()
        close(conn.fd)
    }
}

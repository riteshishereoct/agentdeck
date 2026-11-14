import Foundation
import Darwin

public enum DaemonError: Error, Equatable { case socketPathTooLong(bytes: Int), alreadyRunning, bindFailed(errno: Int32) }

public final class SocketServer {
    public static let maxPathBytes = 103   // sun_path is char[104] including the NUL
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()
    private static let queueKey = DispatchSpecificKey<Void>()

    private let path: String
    private let queue: DispatchQueue
    private let handler: (HTTPRequest, Connection) -> Void
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]

    public init(path: String, queue: DispatchQueue, handler: @escaping (HTTPRequest, Connection) -> Void) {
        self.path = path; self.queue = queue; self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    private static func address(_ path: String) -> sockaddr_un {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &a.sun_path) { p in
            path.withCString { _ = strncpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count - 1) }
        }
        return a
    }

    private static func connectOK(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var a = address(path)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    public func start() throws {
        _ = Self.ignoreSigpipe
        let bytes = path.utf8.count
        guard bytes <= Self.maxPathBytes else { throw DaemonError.socketPathTooLong(bytes: bytes) }

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)

        var st = stat()
        if lstat(path, &st) == 0 {
            if Self.connectOK(path) { throw DaemonError.alreadyRunning }   // never unlink a live daemon's socket
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw DaemonError.bindFailed(errno: EEXIST) }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.bindFailed(errno: errno) }
        var a = Self.address(path)
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        let bindErrno = errno
        umask(old)
        guard rc == 0 else { Darwin.close(fd); throw DaemonError.bindFailed(errno: bindErrno) }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let e = errno; Darwin.close(fd); unlink(path); throw DaemonError.bindFailed(errno: e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [self] in acceptAll() }
        src.setCancelHandler { Darwin.close(fd) }
        acceptSource = src
        src.resume()
    }

    private func acceptAll() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }   // EAGAIN (or a transient error): wait for the next event
            let conn = Connection(fd: c, queue: queue)
            let id = ObjectIdentifier(conn)
            connections[id] = conn
            conn.onFinished = { [weak self] in self?.connections[id] = nil }
            conn.begin(handler: handler)
        }
    }

    /// Safe off-queue.
    public func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { teardown() } else { queue.sync { teardown() } }
    }

    private func teardown() {
        guard listenFD >= 0 else { return }
        listenFD = -1
        acceptSource?.cancel(); acceptSource = nil
        for c in Array(connections.values) { c.close() }
        connections.removeAll()
        unlink(path)
    }
}

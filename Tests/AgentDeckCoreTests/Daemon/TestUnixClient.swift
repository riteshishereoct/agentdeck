import Darwin
import Foundation

/// Raw AF_UNIX client for daemon tests: a blocking fd with poll()-based reads.
final class TestUnixClient {
    private(set) var fd: Int32 = -1
    init(path: String) throws {
        precondition(path.utf8.count <= 103, "sun_path is 104 bytes including NUL")
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b } }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { let e = errno; Darwin.close(fd); fd = -1; throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
    }
    func send(_ s: String) { let b = Array(s.utf8); _ = b.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }
    /// Reads until EOF or until `seconds` pass; returns the bytes and whether EOF was seen.
    func read(for seconds: TimeInterval) -> (data: Data, eof: Bool) {
        var out = Data(), buf = [UInt8](repeating: 0, count: 65_536)
        let end = Date().addingTimeInterval(seconds)
        while true {
            let left = end.timeIntervalSinceNow
            if left <= 0 { return (out, false) }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, Int32(left * 1000) + 1) <= 0 { continue }
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return (out, true) }
            out.append(buf, count: n)
        }
    }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}

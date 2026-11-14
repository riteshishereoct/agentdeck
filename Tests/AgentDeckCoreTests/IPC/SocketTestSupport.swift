import XCTest
import Darwin
@testable import AgentDeckCore

class SocketTestCase: XCTestCase {
    let queue = DispatchQueue(label: "agentdeck.core.test")
    var server: SocketServer?
    var root = ""
    var path: String { root + "/s.sock" }
    override func setUp() {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("adk.\(UUID().uuidString.prefix(6))")
        precondition(path.utf8.count <= 103, "socket path exceeds sun_path")   // protocol §1: assert the length first
    }
    override func tearDown() { server?.stop(); try? FileManager.default.removeItem(atPath: root) }
    func startServer(_ handler: @escaping (HTTPRequest, Connection) -> Void) throws {
        server = SocketServer(path: path, queue: queue, handler: handler); try server!.start()
    }
}

final class RawClient {
    let fd: Int32
    init(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            path.withCString { _ = strncpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count - 1) }
        }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(rc == 0, "connect failed, errno \(errno)")
    }
    func send(_ s: String) { let b = Array(s.utf8); _ = Darwin.send(fd, b, b.count, 0) }
    /// Reads until `needle` appears, EOF, or the timeout.
    func read(timeout: TimeInterval, until needle: String? = nil) -> (text: String, eof: Bool) {
        var out = Data(); var eof = false; let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, Int32(max(1, end.timeIntervalSinceNow * 1000))) <= 0 { break }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { eof = true; break }
            out.append(contentsOf: buf[0..<n])
            if let needle, String(decoding: out, as: UTF8.self).contains(needle) { break }
        }
        return (String(decoding: out, as: UTF8.self), eof)
    }
    deinit { Darwin.close(fd) }
}

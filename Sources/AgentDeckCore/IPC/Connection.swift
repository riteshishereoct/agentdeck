import Foundation
import Darwin

/// One accepted fd. All methods and callbacks run on the core queue.
public final class Connection {
    static let requestDeadline: TimeInterval = 2.0

    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var requestComplete = false
    private var continueSent = false
    private var closed = false
    var onFinished: (() -> Void)?   // server bookkeeping; fires on every close path
    /// Fires once when the peer closes or a write fails; never after the caller's own `close()`.
    public var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Starts reading; `handler` runs once, on the queue, when a full request has arrived.
    func begin(handler: @escaping (HTTPRequest, Connection) -> Void) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        src.setEventHandler { [self] in readable(handler) }
        src.setCancelHandler { Darwin.close(fd) }
        readSource = src
        src.resume()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.requestDeadline)
        t.setEventHandler { [self] in if !requestComplete { close() } }
        timer = t
        t.resume()
    }

    private func readable(_ handler: (HTTPRequest, Connection) -> Void) {
        var eof = false
        var chunk = [UInt8](repeating: 0, count: 262_144)
        while !closed {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                if !requestComplete { buffer.append(contentsOf: chunk[0..<n]) }   // after the request, bytes are discarded
            } else if n == 0 {
                eof = true; break
            } else if errno == EINTR {
                continue
            } else {
                if errno != EAGAIN && errno != EWOULDBLOCK { eof = true }
                break
            }
        }
        if !requestComplete && !closed && !buffer.isEmpty { parse(handler) }
        if eof { finishPeerGone() }
    }

    private func parse(_ handler: (HTTPRequest, Connection) -> Void) {
        switch HTTPParser.parse(buffer) {
        case .needMore: break
        case .expectContinue:
            if !continueSent {
                continueSent = true
                if !rawWrite(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) { finishPeerGone() }
            }
        case .error(let status):
            respond(status: status, body: Data(), contentType: nil)
        case .complete(let req, _):
            requestComplete = true
            buffer = Data()
            timer?.cancel(); timer = nil
            handler(req, self)
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    public func respond(status: Int, body: Data, contentType: String?) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if status != 204 {
            if let contentType { head += "Content-Type: \(contentType)\r\n" }
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if status != 204 { out.append(body) }
        _ = rawWrite(out)
        close()
    }

    /// Idempotent; never fires `onClose`.
    public func close() {
        guard !closed else { return }
        teardown()
    }

    private func finishPeerGone() {
        guard !closed else { return }
        let cb = onClose
        onClose = nil
        teardown()
        cb?()
    }

    /// Writes the 200 headers of a streamed body (no Content-Length); `write` then sends the body.
    public func startStream(contentType: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        if !rawWrite(Data(head.utf8)) { finishPeerGone() }
    }

    /// False when closed or the peer is gone (which also closes and fires `onClose`).
    public func write(_ data: Data) -> Bool {
        guard rawWrite(data) else { finishPeerGone(); return false }
        return true
    }

    private func teardown() {
        closed = true
        timer?.cancel(); timer = nil
        readSource?.cancel(); readSource = nil   // the cancel handler closes the fd
        let finished = onFinished
        onFinished = nil
        finished?()
    }

    private func rawWrite(_ data: Data) -> Bool {
        if closed { return false }
        if data.isEmpty { return true }
        return data.withUnsafeBytes { p in
            var off = 0
            while off < data.count {
                let n = send(fd, p.baseAddress! + off, data.count - off, 0)
                if n < 0 { if errno == EINTR { continue }; return false }   // EPIPE, ECONNRESET, EAGAIN: the peer is gone
                off += n
            }
            return true
        }
    }
}

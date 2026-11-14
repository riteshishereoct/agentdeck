import Foundation

/// HoldWaiter over one `GET /v1/wait/<id>` connection (protocol §2.4). Core queue only.
/// `init` is side-effect free; `start()` begins streaming, so a rejected wait never wires `onClose` to a live hold.
public final class WaitStream: HoldWaiter {
    private let connection: Connection
    private let queue: DispatchQueue
    private let onClosed: () -> Void
    private var timer: DispatchSourceTimer?
    private var done = false
    private static let beat = Data(repeating: 0x20, count: 4)

    public init(connection: Connection, queue: DispatchQueue, onClosed: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.onClosed = onClosed
    }

    public func start() {
        connection.onClose = { [self] in peerGone() }
        connection.startStream(contentType: "application/json")
        guard !done, connection.write(Self.beat) else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [self] in if !done, !connection.write(Self.beat) { peerGone() } }
        timer = t
        t.resume()
    }

    /// nil = release: close after heartbeats only.
    public func finish(_ body: Data?) {
        guard !done else { return }
        stop()
        if let body { _ = connection.write(body) }
        connection.close()
    }

    private func peerGone() {
        guard !done else { return }
        stop()
        connection.close()
        onClosed()
    }

    private func stop() {
        done = true
        timer?.cancel(); timer = nil
        connection.onClose = nil
    }
}

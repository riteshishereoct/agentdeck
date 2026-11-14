import AppKit
import AgentDeckCore

/// Samples frontmost app + idle time. Needs no TCC permission (NSWorkspace and CGEventSource idle time are prompt-free).
final class PresenceMonitor {
    private let daemon: Daemon
    private let onSnapshot: (PresenceSnapshot) -> Void
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(daemon: Daemon, onSnapshot: @escaping (PresenceSnapshot) -> Void) {
        self.daemon = daemon; self.onSnapshot = onSnapshot
    }

    func start() {
        guard timer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.sample() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = 0.2
        sample()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o); observer = nil }
    }

    private func sample() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let snap = PresenceSnapshot(frontmostBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, idleSeconds: idle, at: Date())
        daemon.update(presence: snap)
        onSnapshot(snap)
    }
}

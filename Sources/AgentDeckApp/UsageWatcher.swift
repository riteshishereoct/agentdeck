import Foundation
import AgentDeckCore

/// Event-driven (no timer, no polling): watches the ~/.agentdeck directory because the file is replaced via mv (new inode).
final class UsageWatcher {
    private let dir: String, file: String
    private let queue = DispatchQueue(label: "agentdeck.usage")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: (UsageSnapshot?) -> Void

    init(onChange: @escaping (UsageSnapshot?) -> Void) {
        dir = NSHomeDirectory() + "/.agentdeck"; file = dir + "/usage.json"; self.onChange = onChange
    }

    func start() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            s.setEventHandler { [weak self] in self?.debouncedRead() }
            s.setCancelHandler { close(fd) }
            s.resume(); source = s
        }
        read()
    }

    func read() {
        let snap = UsageSnapshot.parse(FileManager.default.contents(atPath: file))
        DispatchQueue.main.async { self.onChange(snap) }
    }

    private func debouncedRead() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.read() }
        pending = w
        queue.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    deinit { source?.cancel() }
}

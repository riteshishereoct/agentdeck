import Foundation

/// Metadata-only log (callers never pass tool input). Rotates to `<name>.1` at `maxBytes`. Not thread-safe: core queue.
public final class MetaLog {
    private let url: URL
    private let maxBytes: Int

    public init(url: URL, maxBytes: Int = 5_242_880) {
        self.url = url; self.maxBytes = maxBytes
    }

    public func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size >= maxBytes {
            let backup = url.appendingPathExtension("1")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((line + "\n").utf8))
    }
}

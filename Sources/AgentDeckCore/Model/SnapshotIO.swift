import Foundation

/// Metadata-only session snapshot (spec: no previews, steps, prompts, summaries or requests). The goal (a prompt excerpt) is
/// never written: on load it is re-derived from the session's own transcript. `title` is Claude's ai-title (or summary line).
public enum SnapshotIO {
    private struct Entry: Codable {
        var id: String, project: String, cwd: String
        var workspaceRoot: String?
        var transcriptPath: String?, pid: Int32?, host: String?, entrypoint: String?, title: String?, model: String?
        var startedAt: Date, lastEventAt: Date
    }
    private struct File: Codable { var version: Int; var sessions: [Entry] }

    public static func save(_ sessions: [Session], to url: URL) throws {
        let entries = sessions.map {
            Entry(id: $0.id, project: $0.project, cwd: $0.cwd, workspaceRoot: $0.workspaceRoot, transcriptPath: $0.transcriptPath, pid: $0.pid, host: $0.host,
                  entrypoint: $0.entrypoint, title: $0.title, model: $0.model,
                  startedAt: $0.startedAt, lastEventAt: $0.lastEventAt)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(File(version: 1, sessions: entries))
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Temp file created 0600, then renamed over the target: never world-readable, never half-written.
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, url.path) == 0 else { try? fm.removeItem(at: tmp); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func load(from url: URL) -> [Session] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(File.self, from: data), f.version == 1 else { return [] }
        return f.sessions.map {
            SessionLabels.restoringContext(Session(id: $0.id, project: $0.project, cwd: $0.cwd, workspaceRoot: $0.workspaceRoot, transcriptPath: $0.transcriptPath, pid: $0.pid, host: $0.host,
                    entrypoint: $0.entrypoint, title: $0.title, model: $0.model, state: .idle,
                    startedAt: $0.startedAt, lastEventAt: $0.lastEventAt))
        }
    }
}

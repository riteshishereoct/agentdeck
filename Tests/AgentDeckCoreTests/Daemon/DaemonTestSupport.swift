import XCTest
import Darwin
@testable import AgentDeckCore

let bashBody: [String: Any] = ["session_id": "s1", "cwd": "/p", "tool_name": "Bash",
                               "tool_input": ["command": "npm install"], "permission_mode": "default"]
final class DaemonHarness {
    let home: URL, paths: AppPaths, daemon: Daemon
    private let lock = NSLock(); private var _updates: [(String, RequestStatus)] = []
    var updates: [(String, RequestStatus)] { lock.lock(); defer { lock.unlock() }; return _updates }

    init(categories: [String: Int] = [:], settings: AppSettings = AppSettings(), clock: Clock = SystemClock(), start: Bool = true) throws {
        var t = Array("/tmp/adk.XXXXXX".utf8CString)      // short HOME: the temporaryDirectory path would exceed 103 bytes
        guard mkdtemp(&t) != nil else { throw POSIXError(.EIO) }
        home = URL(fileURLWithPath: String(cString: t))
        paths = AppPaths.live(home: home)
        XCTAssertLessThanOrEqual(paths.socket.path.utf8.count, 103)
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        if !categories.isEmpty { try DaemonHarness.writeMatrix(categories, to: paths.capabilities) }
        daemon = Daemon(paths: paths, settings: settings, clock: clock)
        daemon.emitObserver = { [weak self] ev in
            guard let self, case .requestUpdated(let id, let s) = ev.kind else { return }
            self.lock.lock(); self._updates.append((id, s)); self.lock.unlock()
        }
        if start { try daemon.start() }
    }
    static func writeMatrix(_ c: [String: Int], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: ["version": 1, "categories": c]).write(to: url)
    }
    func stop() { daemon.stop(); try? FileManager.default.removeItem(at: home) }
    func launchCurl(_ args: [String], host: String? = cursor) -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--unix-socket", paths.socket.path] + (host.map { ["-H", "X-Adeck-Host: \($0)"] } ?? []) + args
        p.standardOutput = Pipe(); try! p.run(); return p
    }
    static func output(_ p: Process) -> Data { p.waitUntilExit(); return (p.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile() }
    @discardableResult func curl(_ args: [String], host: String? = cursor) -> String {
        String(decoding: DaemonHarness.output(launchCurl(args, host: host)), as: UTF8.self)
    }
    @discardableResult func post(_ route: String, _ body: [String: Any], headers: [String] = []) -> String {
        curl(headers.flatMap { ["-H", $0] } + ["--data-binary", String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self), "http://adeck\(route)"])
    }
    func code(_ args: [String]) -> String { curl(["-o", "/dev/null", "-w", "%{http_code}"] + args) }
    func waitUntil(_ seconds: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; usleep(20_000) }
        return cond()
    }
    func resolve(_ id: String, _ d: Decision, _ s: DecisionSource = .click) -> ResolveResult {
        let e = XCTestExpectation(description: "resolve"); var r = ResolveResult.dropped(.unknownOrResolved)
        daemon.resolve(requestId: id, decision: d, source: s) { r = $0; e.fulfill() }
        _ = XCTWaiter().wait(for: [e], timeout: 2); return r
    }
}

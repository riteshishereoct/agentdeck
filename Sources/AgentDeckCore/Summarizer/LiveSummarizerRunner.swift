import Foundation

/// Runs a nested `claude -p` for the opt-in summarizer. Hooks are disabled for the nested call (ADECK_NESTED=1 and disableAllHooks), so it can never reach this daemon.
public final class LiveSummarizerRunner: SummarizerRunner {
    public static var arguments: [String] { ["-p", "--model", "claude-haiku-5-5", "--settings", #"{"disableAllHooks":true}"#] }
    public static func environment(base: [String: String]) -> [String: String] { base.merging(["ADECK_NESTED": "1"]) { _, new in new } }

    private let executable: String?
    private let callbackQueue: DispatchQueue
    private let timeout: TimeInterval

    public init(executable: String? = nil, callbackQueue: DispatchQueue, timeout: TimeInterval = 30) {
        self.executable = executable; self.callbackQueue = callbackQueue; self.timeout = timeout
    }

    private static func resolve() -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(prompt: String, completion: @escaping (String?) -> Void) {
        let queue = callbackQueue
        guard let path = executable ?? Self.resolve(), FileManager.default.isExecutableFile(atPath: path) else {
            queue.async { completion(nil) }; return
        }
        DispatchQueue.global(qos: .utility).async { [timeout] in
            let p = Process(), stdin = Pipe(), stdout = Pipe()
            p.executableURL = URL(fileURLWithPath: path); p.arguments = Self.arguments
            p.environment = Self.environment(base: ProcessInfo.processInfo.environment)
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { queue.async { completion(nil) }; return }
            let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8)); try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); kill.cancel()
            let text = p.terminationStatus == 0 ? String(data: out, encoding: .utf8) : nil
            queue.async { completion(text) }
        }
    }
}

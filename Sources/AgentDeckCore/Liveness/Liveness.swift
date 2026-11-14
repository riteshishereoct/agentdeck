import Foundation
import Darwin

public enum Liveness {
    public static let checkInterval: TimeInterval = 30

    /// (ppid, p_comm) of a process, nil when it is gone. p_comm is truncated to 16 bytes by the kernel.
    public static func processInfo(_ pid: Int32) -> (ppid: Int32, name: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return (info.kp_eproc.e_ppid, name)
    }

    /// Amendment A1: the first of `pid` and its next ≤ 5 ancestors named `claude` or `node`; nil = unknown (never "dead").
    public static func resolveClaudePid(_ pid: Int32, lookup: (Int32) -> (ppid: Int32, name: String)?) -> Int32? {
        var cur = pid
        for _ in 0...5 {
            guard let info = lookup(cur) else { return nil }
            if info.name == "claude" || info.name == "node" { return cur }
            if info.ppid <= 1 { return nil }
            cur = info.ppid
        }
        return nil
    }

    public static func resolveClaudePid(_ pid: Int32) -> Int32? { resolveClaudePid(pid, lookup: processInfo) }

    public static func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
}

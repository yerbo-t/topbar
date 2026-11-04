import Foundation
import Darwin

public enum ProcessProbe {
    private static func info(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Время старта процесса (секунды с эпохи); nil, если процесса нет.
    public static func startTime(pid: Int32) -> Double? {
        guard let i = info(pid: pid) else { return nil }
        let t = i.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    public static func parentPid(of pid: Int32) -> Int32? {
        info(pid: pid).map { $0.kp_eproc.e_ppid }
    }

    public static func name(of pid: Int32) -> String? {
        guard var i = info(pid: pid) else { return nil }
        return withUnsafePointer(to: &i.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// Терминальное устройство процесса («ttys003»); nil, если у процесса нет терминала.
    public static func ttyName(of pid: Int32) -> String? {
        guard let i = info(pid: pid) else { return nil }
        let dev = i.kp_eproc.e_tdev
        guard dev != -1, let c = devname(dev, mode_t(S_IFCHR)) else { return nil }
        return String(cString: c)
    }

    /// Процесс жив и это тот же процесс (время старта совпадает), а не переиспользованный pid.
    public static func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        guard let started = startTime(pid: pid) else { return false }
        guard let startedAt else { return true }
        return abs(started - startedAt) < 2
    }

    /// Первый предок (включая сам `pid`), чьё имя подходит под условие.
    public static func ancestorPid(matching isMatch: (String) -> Bool, from pid: Int32, maxDepth: Int = 8) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            if let n = name(of: current), isMatch(n) { return current }
            guard let parent = parentPid(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Дочерние процессы (по таблице процессов; для интервала в секунды этого достаточно).
    public static func childPids(of pid: Int32) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var bytes = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &buffer, &bytes, nil, 0) == 0 else { return [] }
        return buffer.prefix(bytes / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_ppid == pid }
            .map { $0.kp_proc.p_pid }
    }
}

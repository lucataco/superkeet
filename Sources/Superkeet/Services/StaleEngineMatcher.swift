import Darwin
import Foundation

/// Decides whether a process named in Superkeet's pid file is a speech engine Superkeet started.
/// Matching the exact binary path alone misses an engine left over from before the app was moved
/// (or run from App Translocation), which then held the model in memory for good. A `parakeet`
/// binary serving Superkeet's own socket is just as surely ours.
enum StaleEngineMatcher {
    static func isOurEngine(executablePath: String, arguments: [String], expectedBinary: String, socketPath: String) -> Bool {
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        if executable.path == URL(fileURLWithPath: expectedBinary).standardizedFileURL.path { return true }
        guard executable.lastPathComponent == "parakeet", arguments.contains("serve") else { return false }
        guard let flag = arguments.firstIndex(of: "--socket"), arguments.indices.contains(flag + 1) else { return false }
        return URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL.path
            == URL(fileURLWithPath: socketPath).standardizedFileURL.path
    }
}

/// Reads another process's argument vector (`KERN_PROCARGS2`).
enum ProcessArguments {
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// Layout: argc (Int32), executable path, NUL padding, then argc NUL-terminated arguments.
    static func parse(_ buffer: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return nil }
        let argc = buffer.prefix(countSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var index = countSize
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "")
            index += 1
        }
        return arguments
    }
}

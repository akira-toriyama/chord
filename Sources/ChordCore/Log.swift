import Foundation

/// Centralised logging for chord. Lives in `ChordCore` so both
/// adapter and app modules can call it without crossing layer rules.
///
/// `Log.line` is always on (operational events the user should be
/// able to see in a bug report). `Log.debug` is gated by
/// `Log.debugMode`, set from the `CHORD_DEBUG` env var at startup.
///
/// Both write to `/tmp/chord.log`. `CHORD_DEBUG` also mirrors to stderr
/// so foreground users see events live and bug reports can capture
/// them with `2>&1 | tee bug.log`. Non-debug runs stay quiet on
/// stderr so a backgrounded `chord &` doesn't pollute the launching
/// shell.
public enum Log {
    nonisolated(unsafe) public static var debugMode = false
    public static let path = "/tmp/chord.log"
    /// chord 0.9.0+: per-event structured log file the `--watch`
    /// client tails. The daemon only writes here **while the file
    /// already exists** — the existence of the file IS the subscription
    /// signal. `chord --watch` creates / truncates it on start;
    /// `rm /tmp/chord-watch.log` silences the daemon's per-event
    /// output immediately.
    public static let watchPath = "/tmp/chord-watch.log"

    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func line(_ message: @autoclosure () -> String) {
        emit(message(), mirrorToStderrOverride: nil)
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard debugMode else { return }
        emit(message(), mirrorToStderrOverride: nil)
    }

    /// Per-event structured line for `chord --watch`. Cheap no-op
    /// when the watch file doesn't exist (i.e. no client has run
    /// `chord --watch` since this daemon start). Writes only to the
    /// watch file, never mirrored to stderr or to the main log.
    public static func watch(_ message: @autoclosure () -> String) {
        guard FileManager.default.fileExists(atPath: watchPath) else {
            return
        }
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message())\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8),
              let h = FileHandle(forWritingAtPath: watchPath)
        else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private static func emit(_ message: String, mirrorToStderrOverride: Bool?) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let h = FileHandle(forWritingAtPath: path) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        let mirror = mirrorToStderrOverride ?? debugMode
        if mirror {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

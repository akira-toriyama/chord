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

import Foundation

/// IPC between the chord daemon and its own CLI clients (`chord
/// --reload`, `chord --quit`). Same pattern as facet / stroke —
/// Distributed Notification Center, fire-and-forget. The daemon is
/// the listener; clients post and exit.
///
/// `--status` is one-way the other direction: DNC has no reply
/// channel, so the daemon writes a small status file at
/// [statusPath] on start / reload / each dispatch, and `--status`
/// just reads it.
public enum Control {
    public static let center = "com.chord.app.control"
    public static let reload = "chord.reload"
    public static let quit   = "chord.quit"
    public static let pause  = "chord.pause"
    public static let resume = "chord.resume"

    public static let statusPath = "/tmp/chord.status"

    /// Wait briefly to see if the daemon actually acted on a posted
    /// notification by watching the status file's mtime.
    public static func postAndWait(_ name: String, timeout: TimeInterval = 2.0)
        -> Bool
    {
        let before = mtime(statusPath)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: center,
            userInfo: nil,
            deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if mtime(statusPath) > before { return true }
        }
        return false
    }

    public static func writeStatus(_ status: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(status)\n"
        try? line.write(toFile: statusPath, atomically: true, encoding: .utf8)
    }

    public static func readStatus() -> String? {
        try? String(contentsOfFile: statusPath, encoding: .utf8)
    }

    private static func mtime(_ path: String) -> TimeInterval {
        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: path) else { return 0 }
        return (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}

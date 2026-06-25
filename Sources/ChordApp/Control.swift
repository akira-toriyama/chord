import ChordCore
import Foundation

/// IPC between the chord daemon and its own CLI clients (`chord
/// daemon --reload`, `chord daemon --quit`). Same pattern as facet /
/// stroke — Distributed Notification Center, fire-and-forget. The
/// daemon is the listener; clients post and exit.
///
/// `daemon --show` is one-way the other direction: DNC has no reply
/// channel, so the daemon writes a small status file at
/// [statusPath] on start / reload / each dispatch, and `daemon --show`
/// just reads it.
///
/// [query] is the THIRD shape: a read-only request/response over the
/// AF_UNIX socket at [QuerySchema.socketPath], for structured runtime
/// state the scalar status file can't carry (live vars, counts,
/// recent-fires history). Control stays write-only (DNC); the status
/// file stays the one scalar line; structured reads use the query
/// socket. See chord's CLAUDE.md §IPC.
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

    /// Read-only query to the running daemon over the AF_UNIX
    /// request/response socket ([QuerySchema.socketPath]). Sends one
    /// request line, reads the JSON reply to EOF, returns it verbatim
    /// (the daemon owns the wire format). Returns nil when no daemon is
    /// listening — a missing socket file OR a refused connect (a stale
    /// socket after a crash) both mean "not running" → the caller maps
    /// it to exit 3. A short socket timeout caps a wedged daemon, same
    /// don't-block-forever discipline as [postAndWait].
    public static func query(_ request: QuerySchema.Request,
                             timeout: TimeInterval = 2.0) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard let (addr, len) = makeUnixSocketAddr(path: QuerySchema.socketPath)
        else { return nil }   // fd closed by the `defer` above
        let connected = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return nil }   // ENOENT / ECONNREFUSED → no daemon

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig,
                   socklen_t(MemoryLayout<Int32>.size))

        // Send the request line.
        let reqBytes = Array(request.line.utf8)
        reqBytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < reqBytes.count {
                let n = write(fd, base + off, reqBytes.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }   // interrupted — retry
                break                                      // timeout / peer gone
            }
        }

        // Read the reply to EOF.
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { out.append(contentsOf: chunk[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }   // interrupted — retry
            break                                      // EOF / timeout / error
        }
        guard !out.isEmpty else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    private static func mtime(_ path: String) -> TimeInterval {
        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: path) else { return 0 }
        return (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}

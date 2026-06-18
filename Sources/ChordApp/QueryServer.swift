import ChordAdapterMacOS
import ChordCore
import Foundation

/// The read-only query server: an AF_UNIX request/response socket the
/// daemon listens on so external tools can read live runtime state
/// (`chord query --status` / `--vars` / `--loaded-bindings` /
/// `--recent-fires`). See [QuerySchema] for the wire contract and
/// chord's CLAUDE.md §IPC for why this is a *separate* primitive from
/// the DNC control channel (write-only) and the status file (one
/// scalar line).
///
/// Threading: the accept loop + per-connection I/O run on a private
/// serial queue ([queryQueue]); responses are built from the same
/// lock-guarded snapshots the tap thread reads (paused flag / state
/// store / matcher) plus a small MainActor-published metadata block
/// ([sharedMeta]). The tap hot path is never touched — `recordFire`
/// is one NSLock + a ring append, strictly cheaper than the
/// `writeStatus` file write already on that line.
extension Controller {

    /// Bind + listen on the query socket and arm a DispatchSource that
    /// accepts connections on [queryQueue]. Non-fatal: a bind failure
    /// just disables the query API (the daemon keeps running). Called
    /// from `start()` on the main actor.
    func installQueryServer() {
        let path = QuerySchema.socketPath
        unlink(path)   // clear a stale socket left by a crashed prior daemon
        guard let fd = queryBindListen(path: path) else {
            Log.line("query: socket unavailable at \(path) — query API disabled")
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queryQueue)
        let weakSelf = WeakWrap(self)
        // The handlers run on `queryQueue`, NOT main — so they must be
        // non-isolated. `installQueryServer` is @MainActor, and
        // `setEventHandler`'s parameter is not @Sendable, so an inline
        // closure would inherit MainActor isolation and trap the
        // executor assertion off-main. Typing them `@Sendable` forces
        // non-isolation (same as the tap's `source.start` handler).
        let onEvent: @Sendable () -> Void = {
            // The read source coalesces; drain every pending connection.
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }   // EWOULDBLOCK / EAGAIN → drained
                guard let me = weakSelf.value else { close(client); continue }
                me.handleQueryConnection(client)
            }
        }
        let onCancel: @Sendable () -> Void = {
            close(fd)
            unlink(path)
        }
        src.setEventHandler(handler: onEvent)
        src.setCancelHandler(handler: onCancel)
        src.resume()
        self.querySource = src
        Log.line("query: listening on \(path)")
    }

    /// Cancel the accept loop and remove the socket file. Called from
    /// `stop()`; the cancel handler does the close + unlink.
    func teardownQueryServer() {
        querySource?.cancel()
        querySource = nil
    }

    // MARK: - recent-fires capture (tap thread)

    /// Append a fired binding to the recent-fires ring. Called from the
    /// tap hot path; the lock window is the ring append only, and the
    /// timestamp is stored raw (formatted lazily at query time) to keep
    /// the fire cheap.
    nonisolated func recordFire(name: String, app: String?, action: String) {
        firesLock.lock(); defer { firesLock.unlock() }
        recentFires.append(FireEntry(at: Date(), name: name, app: app, action: action))
    }

    // MARK: - metadata publish (main actor → off-main reads)

    /// Stamp the daemon's start time (uptime baseline). Called once
    /// from `start()`.
    nonisolated func publishStartMeta() {
        metaLock.lock(); defer { metaLock.unlock() }
        sharedMeta.startedAt = Date()
    }

    /// Publish the config-load timestamp + alias counts the query path
    /// can't otherwise reach without @MainActor. Called from
    /// `loadConfig` after each (re)load.
    nonisolated func publishConfigMeta(actionAliases: Int, inputAliases: Int) {
        metaLock.lock(); defer { metaLock.unlock() }
        sharedMeta.configLoadedAt = Date()
        sharedMeta.actionAliasCount = actionAliases
        sharedMeta.inputAliasCount = inputAliases
    }

    // MARK: - per-connection handling (query queue)

    /// Read one request line, build the JSON response, write it back,
    /// close. Bounded by a short socket timeout so a silent client
    /// can't wedge the serial queue.
    nonisolated private func handleQueryConnection(_ fd: Int32) {
        defer { close(fd) }
        queryDisableSigPipe(fd)
        // The accepted fd inherits the listening socket's O_NONBLOCK on
        // macOS; clear it so the read below BLOCKS (bounded by the recv
        // timeout) instead of racing the client's request bytes — else
        // the first connection after startup reads EAGAIN and replies
        // empty.
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        guard let line = queryReadLine(fd) else { return }
        let body: Data
        if let req = QuerySchema.Request(line: line) {
            body = buildQueryResponse(req)
        } else {
            body = QuerySchema.errorJSON("unknown query endpoint or malformed request")
        }
        queryWriteAll(fd, body + Data("\n".utf8))
    }

    /// Build the JSON document for one request from lock-guarded
    /// snapshots — no @MainActor hop, so the query path is fully
    /// self-contained on [queryQueue].
    nonisolated private func buildQueryResponse(_ req: QuerySchema.Request) -> Data {
        let now = Date()
        let iso = QuerySchema.iso(now)
        let meta = readMeta()
        switch req.endpoint {
        case .status:
            let uptime = meta.startedAt
                .map { Swift.max(0, Int(now.timeIntervalSince($0))) } ?? 0
            return QuerySchema.encode(QuerySchema.StatusResponse(
                queriedAt: iso,
                paused: isPaused(),
                // Cheap (in-process cached TCC) and intentionally live —
                // the grant can change at runtime, so we don't snapshot it.
                axGranted: Permissions.isAccessibilityTrusted(),
                version: ChordVersion.current,
                uptimeS: uptime,
                configLoadedAt: meta.configLoadedAt.map(QuerySchema.iso),
                inputMonitoringGranted: Permissions.isInputMonitoringTrusted()))
        case .vars:
            return QuerySchema.encode(QuerySchema.VarsResponse(
                queriedAt: iso, vars: variableStore.snapshot().variables))
        case .loadedBindings:
            let m = matcherSnapshot()
            return QuerySchema.encode(QuerySchema.LoadedBindingsResponse(
                queriedAt: iso,
                bindings: m.bindings.count,
                fallbacks: m.fallbacks.count,
                actionAliases: meta.actionAliasCount,
                inputAliases: meta.inputAliasCount))
        case .recentFires:
            return QuerySchema.encode(QuerySchema.RecentFiresResponse(
                queriedAt: iso, fires: firesSnapshot(limit: req.limit)))
        }
    }

    /// Recent fires, newest first, capped at `limit`. Formats the
    /// stored raw timestamps to ISO-8601 here (not on the tap thread).
    nonisolated private func firesSnapshot(limit: Int?) -> [QuerySchema.FireRecord] {
        firesLock.lock(); defer { firesLock.unlock() }
        var records = recentFires.elements().reversed().map { entry in
            QuerySchema.FireRecord(ts: QuerySchema.iso(entry.at), name: entry.name,
                                   app: entry.app, action: entry.action)
        }
        if let limit { records = Array(records.prefix(limit)) }
        return records
    }

    nonisolated private func readMeta() -> DaemonMeta {
        metaLock.lock(); defer { metaLock.unlock() }
        return sharedMeta
    }
}

// MARK: - POSIX socket helpers (file-private)

/// Create + bind + listen on an AF_UNIX stream socket, non-blocking.
/// Returns the listening fd, or nil on any failure (caller logs +
/// disables the query API).
private func queryBindListen(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = path.utf8CString   // includes the trailing NUL
    guard pathBytes.count <= cap else { close(fd); return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: src.count)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    guard bound == 0 else { close(fd); return nil }
    chmod(path, 0o600)   // owner-only; the data is non-sensitive but be tidy
    guard listen(fd, 8) == 0 else { close(fd); unlink(path); return nil }
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    return fd
}

/// Suppress SIGPIPE on a client fd so a write to a hung-up peer fails
/// with EPIPE instead of killing the daemon.
private func queryDisableSigPipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Read one newline-terminated request line (≤256 bytes). Returns nil
/// on EOF / timeout before any byte.
private func queryReadLine(_ fd: Int32) -> String? {
    var bytes = [UInt8]()
    var ch: UInt8 = 0
    while bytes.count < 256 {
        let n = read(fd, &ch, 1)
        if n < 0 && errno == EINTR { continue }   // interrupted — retry
        if n <= 0 { break }                       // EOF / recv timeout / error
        if ch == UInt8(ascii: "\n") { break }
        bytes.append(ch)
    }
    return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
}

/// Write `data` fully (handles short writes). Best-effort: stops on the
/// first error (peer gone) — the connection is closed by the caller.
private func queryWriteAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard var p = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let n = write(fd, p, remaining)
            if n > 0 { p = p.advanced(by: n); remaining -= n; continue }
            if n < 0 && errno == EINTR { continue }   // interrupted — retry
            break                                      // peer gone / timeout
        }
    }
}

// MARK: - cross-thread state (file-private to the query feature)

/// A captured fire, pending formatting at query time — keeps the tap
/// hot path cheap (no date/string formatting on the fire). Mapped to
/// [QuerySchema.FireRecord] when a query reads the ring.
struct FireEntry: Sendable {
    let at: Date
    let name: String
    let app: String?
    let action: String
}

/// Recent-fires history. Written on the tap thread (`recordFire`),
/// snapshot-read on the query queue — the NSLock window is just the
/// ring append / copy, same idiom as `sharedState` / `sharedMatcher`.
nonisolated(unsafe) var recentFires = RingBuffer<FireEntry>(capacity: 256)
let firesLock = NSLock()

/// MainActor-published daemon metadata the query path reads off-main
/// (lock-guarded, same publish-from-main / read-off-main idiom as
/// `sharedMatcher`). bindings / fallbacks counts come straight from the
/// matcher snapshot; only these four aren't reachable without
/// @MainActor.
struct DaemonMeta: Sendable {
    var startedAt: Date?
    var configLoadedAt: Date?
    var actionAliasCount: Int = 0
    var inputAliasCount: Int = 0
}
nonisolated(unsafe) var sharedMeta = DaemonMeta()
let metaLock = NSLock()

/// Serial queue owning the query socket accept loop + per-connection
/// I/O. `.userInitiated` to match the state timer queue; independent of the
/// tap thread (query reads only lock-snapshot the shared state, so the
/// hot path is never blocked).
let queryQueue = DispatchQueue(label: "chord.query", qos: .userInitiated)

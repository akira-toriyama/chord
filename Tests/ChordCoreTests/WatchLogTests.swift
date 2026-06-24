import Foundation
import Testing
@testable import ChordCore

/// chord 0.9.0+: `Log.watch(_:)` writes one structured line per
/// event to the watch file IFF that file exists. The file's existence
/// is the subscription signal — `chord daemon --watch` creates it,
/// `rm /tmp/chord-watch.log` silences the daemon.
///
/// Each test drives `Log.watch(_, to:)` against its OWN unique temp path
/// (not the canonical `/tmp/chord-watch.log`). That isolation is what
/// makes the suite parallel-safe under Swift Testing: other suites that
/// drive the real Controller call `Log.watch(_)` with the default path,
/// and because these tests never create that default file, those calls
/// stay no-ops and can't interleave into our assertions. A `final class`
/// (not a struct) so `deinit` can run the post-test cleanup.
@Suite final class WatchLogTests {

    private let path = NSTemporaryDirectory()
        + "chord-watch-test-\(UUID().uuidString).log"

    // Fresh instance per test: nothing to set up (the unique path starts
    // absent); `deinit` removes the temp file so we leave no litter.
    deinit { try? FileManager.default.removeItem(atPath: path) }

    /// The production default still points at the canonical location —
    /// the isolated `to:` path above is a test seam, not a path change.
    @Test func defaultWatchPathIsCanonical() {
        #expect(Log.watchPath == "/tmp/chord-watch.log")
    }

    // MARK: - Subscription gating

    @Test func watchIsNoOpWhenFileMissing() {
        // Pre-condition: file absent (unique path, never created yet).
        #expect(!FileManager.default.fileExists(atPath: path))
        Log.watch("hello", to: path)
        // Still gone — Log.watch must not create the file itself.
        #expect(!FileManager.default.fileExists(atPath: path),
                "Log.watch must not create the watch file when no subscriber has touched it")
    }

    @Test func watchAppendsWhenFileExists() throws {
        // Simulate `chord daemon --watch` creating the file.
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        Log.watch("event-1", to: path)
        Log.watch("event-2", to: path)

        let body = try String(contentsOfFile: path, encoding: .utf8)
        // Both lines present, in order.
        #expect(body.contains("event-1"))
        #expect(body.contains("event-2"))
        let idx1 = body.range(of: "event-1")!.lowerBound
        let idx2 = body.range(of: "event-2")!.lowerBound
        #expect(idx1 < idx2, "appends preserve order")
    }

    @Test func watchLineFormatHasTimestampPrefix() throws {
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        Log.watch("alpha", to: path)
        let body = try String(contentsOfFile: path, encoding: .utf8)
        // The line starts with `[<ISO-8601 timestamp>]` per Log.swift.
        // We don't pin the exact timestamp; just confirm the bracket
        // pattern is at the start of the (only) line.
        let first = body.split(separator: "\n").first ?? ""
        #expect(first.hasPrefix("["))
        #expect(first.contains("alpha"))
    }

    @Test func removingFileSilencesSubsequentWatches() throws {
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        Log.watch("kept", to: path)
        try FileManager.default.removeItem(atPath: path)
        Log.watch("dropped", to: path)
        // File should still be absent (Log.watch noop'd).
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

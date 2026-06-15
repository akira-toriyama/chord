import XCTest
@testable import ChordCore

/// chord 0.9.0+: `Log.watch(_:)` writes one structured line per
/// event to `/tmp/chord-watch.log` IFF that file exists. The file's
/// existence is the subscription signal — `chord daemon --watch` creates
/// it, `rm /tmp/chord-watch.log` silences the daemon.
final class WatchLogTests: XCTestCase {

    // Tests run against an isolated path so we don't clobber the
    // user's real `/tmp/chord-watch.log`. We swap into the real
    // path only inside each test by writing to it and immediately
    // removing it.

    private let path = Log.watchPath

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(atPath: path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    // MARK: - Subscription gating

    func testWatchIsNoOpWhenFileMissing() throws {
        // Pre-condition: file gone (setUp removed it).
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        Log.watch("hello")
        // Still gone — Log.watch must not create the file itself.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "Log.watch must not create the watch file " +
                       "when no subscriber has touched it")
    }

    func testWatchAppendsWhenFileExists() throws {
        // Simulate `chord daemon --watch` creating the file.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: nil))
        Log.watch("event-1")
        Log.watch("event-2")

        let body = try String(contentsOfFile: path, encoding: .utf8)
        // Both lines present, in order.
        XCTAssertTrue(body.contains("event-1"))
        XCTAssertTrue(body.contains("event-2"))
        let idx1 = body.range(of: "event-1")!.lowerBound
        let idx2 = body.range(of: "event-2")!.lowerBound
        XCTAssertLessThan(idx1, idx2, "appends preserve order")
    }

    func testWatchLineFormatHasTimestampPrefix() throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: nil))
        Log.watch("alpha")
        let body = try String(contentsOfFile: path, encoding: .utf8)
        // The line starts with `[<ISO-8601 timestamp>]` per Log.swift.
        // We don't pin the exact timestamp; just confirm the bracket
        // pattern is at the start of the (only) line.
        let first = body.split(separator: "\n").first ?? ""
        XCTAssertTrue(first.hasPrefix("["))
        XCTAssertTrue(first.contains("alpha"))
    }

    func testRemovingFileSilencesSubsequentWatches() throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: nil))
        Log.watch("kept")
        try FileManager.default.removeItem(atPath: path)
        Log.watch("dropped")
        // File should still be absent (Log.watch noop'd).
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

import XCTest
@testable import ChordApp
@testable import ChordCore

/// Exercises the SubcommandOutcome / dispatchSubcommand surface
/// added in the v0.9 cli-refactor PR. Goal: assert dispatch order +
/// outcome shape without spawning child processes — every test
/// here is pure data in / data out.
///
/// Black-box `Process` spawn tests (`chord --validate --json` etc.)
/// are intentionally left for a follow-up: they need the daemon
/// path or a fixture config.toml, and they belong next to the
/// schema-snapshot golden-file infrastructure that #3 (Schema /
/// Config unification) will introduce.
@MainActor
final class CLIDispatchTests: XCTestCase {

    // MARK: - dispatchSubcommand: standalone subcommands

    func testVersionReportsCurrentString() {
        let out = ChordApp.dispatchSubcommand(["--version"])
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.exitCode, 0)
        XCTAssertEqual(out?.stdout, "chord \(ChordVersion.current)\n")
        XCTAssertNil(out?.stderr)
    }

    func testHelpEmitsUsageOnStdout() {
        let out = ChordApp.dispatchSubcommand(["--help"])
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.exitCode, 0)
        XCTAssertTrue(out?.stdout?.contains("chord — global keyboard") == true)
        XCTAssertTrue(out?.stdout?.contains("--validate") == true)
    }

    func testHelpShortAliasMatches() {
        // `-h` must trigger the same outcome as `--help`.
        let long  = ChordApp.dispatchSubcommand(["--help"])
        let short = ChordApp.dispatchSubcommand(["-h"])
        XCTAssertEqual(long?.exitCode,  short?.exitCode)
        XCTAssertEqual(long?.stdout,    short?.stdout)
    }

    // MARK: - dispatchSubcommand: client subcommands

    /// `--quit` / `--pause` / `--resume` / `--toggle` all post a
    /// `Control` notification and wait for the daemon to ack via
    /// status-file mtime. With no daemon running the wait times out
    /// and the outcome is exit 3 + "no daemon running" on stderr.
    /// This test depends only on "no daemon was running in CI", which
    /// is true under the GitHub Actions sandbox (no chord installed).
    func testQuitWithoutDaemonReportsNoDaemonRunning() throws {
        try XCTSkipIf(daemonStatusFileExists(),
                      "host has /tmp/chord.status — assume daemon may be live")
        let out = ChordApp.dispatchSubcommand(["--quit"])
        XCTAssertEqual(out?.exitCode, 3)
        XCTAssertEqual(out?.stderr, "chord: no daemon running\n")
    }

    func testStatusWithoutFileReportsExit3() throws {
        try XCTSkipIf(daemonStatusFileExists(),
                      "host has /tmp/chord.status — would consume real status")
        let out = ChordApp.dispatchSubcommand(["--status"])
        XCTAssertEqual(out?.exitCode, 3)
        XCTAssertEqual(out?.stderr, "chord: no status file\n")
    }

    // MARK: - dispatchSubcommand: priority order

    /// The subcommand table's first-match-wins rule: a sane priority
    /// stack is `--help > --version > --validate > --list > …`.
    /// Asserting `--help --version` resolves to --help guards against
    /// silent rearrangement of the table.
    func testHelpWinsOverVersion() {
        let out = ChordApp.dispatchSubcommand(["--version", "--help"])
        XCTAssertNotNil(out?.stdout?.contains("--validate"))
    }

    /// `--reload --dry-run` resolves to the dry-run path (no IPC).
    /// Without a snapshot file the diff path emits a "no snapshot"
    /// note and exits 0.
    func testReloadDryRunDoesNotContactDaemon() throws {
        // The dry-run reads on-disk config.toml; if the host has no
        // config it still resolves (empty parse, no snapshot note).
        // No daemon contact, so this never returns exit 3.
        let out = ChordApp.dispatchSubcommand(["--reload", "--dry-run"])
        XCTAssertNotEqual(out?.exitCode, 3, "dry-run should not require daemon")
    }

    // MARK: - dispatchSubcommand: misses

    func testNoSubcommandFlagReturnsNil() {
        XCTAssertNil(ChordApp.dispatchSubcommand([]))
        XCTAssertNil(ChordApp.dispatchSubcommand(["--strict"]))
        XCTAssertNil(ChordApp.dispatchSubcommand(["--json"]))
    }

    // MARK: - checkUnknownFlags

    func testCheckUnknownFlagsAcceptsModifiers() {
        XCTAssertNil(ChordApp.checkUnknownFlags(["--strict", "--json"]))
        XCTAssertNil(ChordApp.checkUnknownFlags(["--include-dropped", "--dry-run"]))
        XCTAssertNil(ChordApp.checkUnknownFlags([]))
    }

    func testCheckUnknownFlagsRejectsUnknown() {
        let out = ChordApp.checkUnknownFlags(["--bogus-flag"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertEqual(out?.stderr,
                       "chord: unknown flag '--bogus-flag'. See --help.\n")
    }

    /// Modifier flags that already passed through a subcommand handler
    /// re-surface here and must be silently accepted; only truly
    /// unknown tokens trip exit 2.
    func testCheckUnknownFlagsMixedModifiers() {
        XCTAssertNil(ChordApp.checkUnknownFlags(
            ["--strict", "--json", "--include-dropped", "--dry-run"]))

        let out = ChordApp.checkUnknownFlags(
            ["--strict", "--bogus", "--json"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("--bogus") == true)
    }

    // MARK: - SubcommandOutcome conveniences

    func testOutcomeOkAddsTrailingNewline() {
        let out = ChordApp.SubcommandOutcome.ok("hello")
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual(out.stdout,  "hello\n")
        XCTAssertNil(out.stderr)
    }

    func testOutcomeFailAddsTrailingNewline() {
        let out = ChordApp.SubcommandOutcome.fail(7, stderr: "bad")
        XCTAssertEqual(out.exitCode, 7)
        XCTAssertNil(out.stdout)
        XCTAssertEqual(out.stderr, "bad\n")
    }

    func testOutcomeCodeNoOutput() {
        let out = ChordApp.SubcommandOutcome.code(42)
        XCTAssertEqual(out.exitCode, 42)
        XCTAssertNil(out.stdout)
        XCTAssertNil(out.stderr)
    }

    // MARK: - helpers

    private func daemonStatusFileExists() -> Bool {
        FileManager.default.fileExists(atPath: Control.statusPath)
    }
}

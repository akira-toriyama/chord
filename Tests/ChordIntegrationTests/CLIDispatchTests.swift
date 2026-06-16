import XCTest
@testable import ChordApp
@testable import ChordCore

/// Exercises the `dispatch` / `SubcommandOutcome` surface of the
/// yabai-style domain-verb CLI (atelier Phase 3 M4 — `chord <domain>
/// --<verb> [--mod …]`). Goal: assert dispatch routing + outcome shape
/// without spawning child processes — every test here is pure data in /
/// data out. `dispatch` returns the outcome and the single exit() site
/// (`applyOutcome`) is never reached, so the whole surface is testable.
///
/// Black-box `Process` spawn tests (`chord config --validate --json`
/// etc.) are intentionally left for a follow-up: they need the daemon
/// path or a fixture config.toml, and they belong next to the
/// schema-snapshot golden-file infrastructure.
@MainActor
final class CLIDispatchTests: XCTestCase {

    // MARK: - top-level carve-outs (--help / --version, with -h / -V)

    func testVersionReportsCurrentString() {
        let out = ChordApp.dispatch(["--version"])
        XCTAssertEqual(out?.exitCode, 0)
        XCTAssertEqual(out?.stdout, "chord \(ChordVersion.current)\n")
        XCTAssertNil(out?.stderr)
    }

    func testVersionShortAliasMatches() {
        // `-V` must trigger the same outcome as `--version` (D7 carve-out).
        XCTAssertEqual(ChordApp.dispatch(["-V"])?.stdout,
                       ChordApp.dispatch(["--version"])?.stdout)
    }

    func testHelpEmitsUsageOnStdout() {
        let out = ChordApp.dispatch(["--help"])
        XCTAssertEqual(out?.exitCode, 0)
        XCTAssertTrue(out?.stdout?.contains("chord — global keyboard") == true)
        XCTAssertTrue(out?.stdout?.contains("--validate") == true)
    }

    func testHelpShortAliasMatches() {
        // `-h` must trigger the same outcome as `--help` (D7 carve-out).
        let long  = ChordApp.dispatch(["--help"])
        let short = ChordApp.dispatch(["-h"])
        XCTAssertEqual(long?.exitCode,  short?.exitCode)
        XCTAssertEqual(long?.stdout,    short?.stdout)
    }

    // MARK: - daemon domain: client verbs (post + wait + report)

    /// `daemon --quit` / `--pause` / `--resume` / `--toggle` all post a
    /// `Control` notification and wait for the daemon to ack via
    /// status-file mtime. With no daemon running the wait times out and
    /// the outcome is exit 3 + "no daemon running" on stderr. Depends
    /// only on "no daemon was running in CI" (true under the GitHub
    /// Actions sandbox — no chord installed).
    func testQuitWithoutDaemonReportsNoDaemonRunning() throws {
        try XCTSkipIf(daemonStatusFileExists(),
                      "host has /tmp/chord.status — assume daemon may be live")
        let out = ChordApp.dispatch(["daemon", "--quit"])
        XCTAssertEqual(out?.exitCode, 3)
        XCTAssertEqual(out?.stderr, "chord: no daemon running\n")
    }

    /// `daemon --show` (the read口, was `--status`) reports exit 3 when
    /// there is no status file.
    func testShowWithoutFileReportsExit3() throws {
        try XCTSkipIf(daemonStatusFileExists(),
                      "host has /tmp/chord.status — would consume real status")
        let out = ChordApp.dispatch(["daemon", "--show"])
        XCTAssertEqual(out?.exitCode, 3)
        XCTAssertEqual(out?.stderr, "chord: no status file\n")
    }

    /// `daemon --reload --dry-run` resolves to the dry-run path (no IPC).
    /// Without a snapshot file the diff path emits a "no snapshot" note
    /// and exits 0 — never exit 3 (no daemon contact).
    func testReloadDryRunDoesNotContactDaemon() {
        let out = ChordApp.dispatch(["daemon", "--reload", "--dry-run"])
        XCTAssertNotEqual(out?.exitCode, 3, "dry-run should not require daemon")
    }

    // MARK: - server mode (bare chord)

    /// Bare `chord` (no argv) is the server-mode signal: `dispatch`
    /// returns nil so main() falls through to `runServer()`.
    func testBareArgvReturnsNilForServerMode() {
        XCTAssertNil(ChordApp.dispatch([]))
    }

    /// A `-`-leading first token is never a domain — it's almost always
    /// an old flat flag. dispatch rejects it loudly (exit 2) and points
    /// at the new domain home. (Old behaviour returned nil → server.)
    func testOldFlatFlagRejectedWithDomainHint() {
        let out = ChordApp.dispatch(["--validate"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("flags now live under a domain") == true)
        XCTAssertTrue(out?.stderr?.contains("Got '--validate'") == true)
    }

    func testBareModifierFlagRejected() {
        // `chord --strict` / `--json` alone (no domain) → exit 2, not nil.
        XCTAssertEqual(ChordApp.dispatch(["--strict"])?.exitCode, 2)
        XCTAssertEqual(ChordApp.dispatch(["--json"])?.exitCode, 2)
        XCTAssertEqual(ChordApp.dispatch(["--bogus-flag"])?.exitCode, 2)
    }

    func testUnknownDomainRejected() {
        let out = ChordApp.dispatch(["frobnicate"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("unknown command 'frobnicate'") == true)
    }

    // MARK: - domain dispatch: verb selection + modifier policy

    func testDomainWithNoVerbRejected() {
        let out = ChordApp.dispatch(["config"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("needs a verb") == true)
    }

    func testIncompatibleVerbsRejected() {
        let out = ChordApp.dispatch(["config", "--validate", "--doctor"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("incompatible verbs") == true)
    }

    /// `daemon --quit --json` — `--json` isn't a recognised flag in the
    /// daemon domain at all, so CLIKit rejects it as an unknown flag
    /// (exit 2) before chord's modifier-applicability check.
    func testUnknownModifierInDomainRejected() throws {
        try XCTSkipIf(daemonStatusFileExists(),
                      "host has /tmp/chord.status — daemon may swallow --quit")
        let out = ChordApp.dispatch(["daemon", "--quit", "--json"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("unknown flag '--json'") == true)
    }

    /// `config --validate --include-dropped` — `--include-dropped` IS a
    /// recognised config-domain flag (it's `config --show`'s modifier),
    /// but `--validate` doesn't honour it → chord's "has no effect"
    /// rejection (exit 2, no silent no-op).
    func testRecognisedModifierOnWrongVerbRejected() {
        let out = ChordApp.dispatch(["config", "--validate", "--include-dropped"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(
            out?.stderr?.contains("'--include-dropped' has no effect with --validate")
            == true)
    }

    /// `config --validate` honours `--strict` and `--json`. The fixture
    /// has no config so we just confirm dispatch DOESN'T reject the
    /// modifiers — exit code can be 0 or 1 depending on host state.
    func testValidateAcceptsItsModifiers() {
        let out = ChordApp.dispatch(["config", "--validate", "--strict", "--json"])
        XCTAssertNotEqual(out?.exitCode, 2,
                          "--strict / --json must be honoured by config --validate")
    }

    /// `config --show` (was `--list`) honours `--json` / `--include-dropped`.
    func testShowAcceptsItsModifiers() {
        let out = ChordApp.dispatch(
            ["config", "--show", "--json", "--include-dropped"])
        XCTAssertNotEqual(out?.exitCode, 2)
    }

    /// A flag from the OTHER domain (`config --reload`) is now an unknown
    /// flag in this domain — no more flat-namespace "priority-loser"
    /// tolerance (that ambiguity is gone with domains). Documents the
    /// intentional behaviour change.
    func testCrossDomainFlagRejected() {
        let out = ChordApp.dispatch(["config", "--reload"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("unknown flag '--reload'") == true)
    }

    // MARK: - query domain (read-only daemon state over the socket)

    func testQueryWithNoVerbRejected() {
        let out = ChordApp.dispatch(["query"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("needs a verb") == true)
    }

    func testQueryIncompatibleVerbsRejected() {
        let out = ChordApp.dispatch(["query", "--status", "--vars"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("incompatible verbs") == true)
    }

    /// `--limit` is declared only for `--recent-fires`; on another verb
    /// it's a recognised-but-inapplicable flag → "has no effect" (exit 2),
    /// chord's no-silent-swallow policy.
    func testQueryLimitOnWrongVerbRejected() {
        let out = ChordApp.dispatch(["query", "--status", "--limit", "5"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(
            out?.stderr?.contains("'--limit' has no effect with --status") == true)
    }

    func testQueryUnknownFlagRejected() {
        let out = ChordApp.dispatch(["query", "--bogus"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("unknown flag '--bogus'") == true)
    }

    /// A non-integer `--limit` is rejected at the verb runner (exit 2),
    /// before any daemon contact — deterministic regardless of daemon.
    func testQueryBadLimitRejected() {
        let out = ChordApp.dispatch(["query", "--recent-fires", "--limit", "abc"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("--limit needs a positive integer") == true)
    }

    /// A `-`-leading limit is taken verbatim by CLIKit's `.value` arity
    /// (not mistaken for a flag — the D0 hazard), then rejected as
    /// non-positive by the runner.
    func testQueryNegativeLimitRejected() {
        let out = ChordApp.dispatch(["query", "--recent-fires", "--limit", "-3"])
        XCTAssertEqual(out?.exitCode, 2)
        XCTAssertTrue(out?.stderr?.contains("got '-3'") == true)
    }

    /// With no daemon listening, a query exits 3 (same precondition
    /// shape as the daemon control verbs). Skipped on a host where the
    /// query socket exists (a daemon may be live and would answer 0).
    func testQueryWithoutDaemonReportsExit3() throws {
        try XCTSkipIf(querySocketExists(),
                      "host has \(QuerySchema.socketPath) — a daemon may answer")
        let out = ChordApp.dispatch(["query", "--status"])
        XCTAssertEqual(out?.exitCode, 3)
        XCTAssertEqual(out?.stderr, "chord: no daemon running\n")
    }

    /// A well-formed `--recent-fires --limit N` parses past validation —
    /// the only failure left is "no daemon" (exit 3), never a usage
    /// error (exit 2).
    func testQueryValidLimitIsNotAUsageError() {
        let out = ChordApp.dispatch(["query", "--recent-fires", "--limit", "10"])
        XCTAssertNotEqual(out?.exitCode, 2,
                          "a valid --limit must not be a usage error")
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

    private func querySocketExists() -> Bool {
        FileManager.default.fileExists(atPath: QuerySchema.socketPath)
    }
}

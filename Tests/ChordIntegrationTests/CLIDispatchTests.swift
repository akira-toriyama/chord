import Foundation
import Testing
@testable import ChordApp
@testable import ChordCore

// Free helpers (were private instance methods). The `.disabled(if:)`
// traits below evaluate their condition without a suite instance, so the
// checks must live outside the type.
private func daemonStatusFileExists() -> Bool {
    FileManager.default.fileExists(atPath: Control.statusPath)
}
private func querySocketExists() -> Bool {
    FileManager.default.fileExists(atPath: QuerySchema.socketPath)
}

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
@Suite @MainActor struct CLIDispatchTests {

    // MARK: - top-level carve-outs (--help / --version, with -h / -V)

    @Test func versionReportsCurrentString() {
        let out = ChordApp.dispatch(["--version"])
        #expect(out?.exitCode == 0)
        #expect(out?.stdout == "chord \(ChordVersion.current)\n")
        #expect(out?.stderr == nil)
    }

    @Test func versionShortAliasMatches() {
        // `-V` must trigger the same outcome as `--version` (D7 carve-out).
        #expect(ChordApp.dispatch(["-V"])?.stdout == ChordApp.dispatch(["--version"])?.stdout)
    }

    @Test func helpEmitsUsageOnStdout() {
        let out = ChordApp.dispatch(["--help"])
        #expect(out?.exitCode == 0)
        #expect(out?.stdout?.contains("chord — global keyboard") == true)
        #expect(out?.stdout?.contains("--validate") == true)
    }

    @Test func helpShortAliasMatches() {
        // `-h` must trigger the same outcome as `--help` (D7 carve-out).
        let long  = ChordApp.dispatch(["--help"])
        let short = ChordApp.dispatch(["-h"])
        #expect(long?.exitCode == short?.exitCode)
        #expect(long?.stdout == short?.stdout)
    }

    // MARK: - daemon domain: client verbs (post + wait + report)

    /// `daemon --quit` / `--pause` / `--resume` / `--toggle` all post a
    /// `Control` notification and wait for the daemon to ack via
    /// status-file mtime. With no daemon running the wait times out and
    /// the outcome is exit 3 + "no daemon running" on stderr. Depends
    /// only on "no daemon was running in CI" (true under the GitHub
    /// Actions sandbox — no chord installed).
    @Test(.disabled(if: daemonStatusFileExists(),
                    "host has /tmp/chord.status — assume daemon may be live"))
    func quitWithoutDaemonReportsNoDaemonRunning() {
        let out = ChordApp.dispatch(["daemon", "--quit"])
        #expect(out?.exitCode == 3)
        #expect(out?.stderr == "chord: no daemon running\n")
    }

    /// `daemon --show` (the read口, was `--status`) reports exit 3 when
    /// there is no status file.
    @Test(.disabled(if: daemonStatusFileExists(),
                    "host has /tmp/chord.status — would consume real status"))
    func showWithoutFileReportsExit3() {
        let out = ChordApp.dispatch(["daemon", "--show"])
        #expect(out?.exitCode == 3)
        #expect(out?.stderr == "chord: no status file\n")
    }

    /// `daemon --reload --dry-run` resolves to the dry-run path (no IPC).
    /// Without a snapshot file the diff path emits a "no snapshot" note
    /// and exits 0 — never exit 3 (no daemon contact).
    @Test func reloadDryRunDoesNotContactDaemon() {
        let out = ChordApp.dispatch(["daemon", "--reload", "--dry-run"])
        #expect(out?.exitCode != 3, "dry-run should not require daemon")
    }

    // MARK: - server mode (bare chord)

    /// Bare `chord` (no argv) is the server-mode signal: `dispatch`
    /// returns nil so main() falls through to `runServer()`.
    @Test func bareArgvReturnsNilForServerMode() {
        #expect(ChordApp.dispatch([]) == nil)
    }

    /// A `-`-leading first token is never a domain — it's almost always
    /// an old flat flag. dispatch rejects it loudly (exit 2) and points
    /// at the new domain home. (Old behaviour returned nil → server.)
    @Test func oldFlatFlagRejectedWithDomainHint() {
        let out = ChordApp.dispatch(["--validate"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("flags now live under a domain") == true)
        #expect(out?.stderr?.contains("Got '--validate'") == true)
    }

    @Test func bareModifierFlagRejected() {
        // `chord --strict` / `--json` alone (no domain) → exit 2, not nil.
        #expect(ChordApp.dispatch(["--strict"])?.exitCode == 2)
        #expect(ChordApp.dispatch(["--json"])?.exitCode == 2)
        #expect(ChordApp.dispatch(["--bogus-flag"])?.exitCode == 2)
    }

    @Test func unknownDomainRejected() {
        let out = ChordApp.dispatch(["frobnicate"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("unknown command 'frobnicate'") == true)
    }

    // MARK: - domain dispatch: verb selection + modifier policy

    @Test func domainWithNoVerbRejected() {
        let out = ChordApp.dispatch(["config"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("needs a verb") == true)
    }

    @Test func incompatibleVerbsRejected() {
        let out = ChordApp.dispatch(["config", "--validate", "--doctor"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("incompatible verbs") == true)
    }

    /// `daemon --quit --json` — `--json` isn't a recognised flag in the
    /// daemon domain at all, so CLIKit rejects it as an unknown flag
    /// (exit 2) before chord's modifier-applicability check.
    @Test(.disabled(if: daemonStatusFileExists(),
                    "host has /tmp/chord.status — daemon may swallow --quit"))
    func unknownModifierInDomainRejected() {
        let out = ChordApp.dispatch(["daemon", "--quit", "--json"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("unknown flag '--json'") == true)
    }

    /// `config --validate --include-dropped` — `--include-dropped` IS a
    /// recognised config-domain flag (it's `config --show`'s modifier),
    /// but `--validate` doesn't honour it → chord's "has no effect"
    /// rejection (exit 2, no silent no-op).
    @Test func recognisedModifierOnWrongVerbRejected() {
        let out = ChordApp.dispatch(["config", "--validate", "--include-dropped"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("'--include-dropped' has no effect with --validate") == true)
    }

    /// `config --validate` honours `--strict` and `--json`. The fixture
    /// has no config so we just confirm dispatch DOESN'T reject the
    /// modifiers — exit code can be 0 or 1 depending on host state.
    @Test func validateAcceptsItsModifiers() {
        let out = ChordApp.dispatch(["config", "--validate", "--strict", "--json"])
        #expect(out?.exitCode != 2, "--strict / --json must be honoured by config --validate")
    }

    /// `config --show` (was `--list`) honours `--json` / `--include-dropped`.
    @Test func showAcceptsItsModifiers() {
        let out = ChordApp.dispatch(["config", "--show", "--json", "--include-dropped"])
        #expect(out?.exitCode != 2)
    }

    /// A flag from the OTHER domain (`config --reload`) is now an unknown
    /// flag in this domain — no more flat-namespace "priority-loser"
    /// tolerance (that ambiguity is gone with domains). Documents the
    /// intentional behaviour change.
    @Test func crossDomainFlagRejected() {
        let out = ChordApp.dispatch(["config", "--reload"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("unknown flag '--reload'") == true)
    }

    // MARK: - query domain (read-only daemon state over the socket)

    @Test func queryWithNoVerbRejected() {
        let out = ChordApp.dispatch(["query"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("needs a verb") == true)
    }

    @Test func queryIncompatibleVerbsRejected() {
        let out = ChordApp.dispatch(["query", "--status", "--vars"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("incompatible verbs") == true)
    }

    /// `--limit` is declared only for `--recent-fires`; on another verb
    /// it's a recognised-but-inapplicable flag → "has no effect" (exit 2),
    /// chord's no-silent-swallow policy.
    @Test func queryLimitOnWrongVerbRejected() {
        let out = ChordApp.dispatch(["query", "--status", "--limit", "5"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("'--limit' has no effect with --status") == true)
    }

    @Test func queryUnknownFlagRejected() {
        let out = ChordApp.dispatch(["query", "--bogus"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("unknown flag '--bogus'") == true)
    }

    /// A non-integer `--limit` is rejected at the verb runner (exit 2),
    /// before any daemon contact — deterministic regardless of daemon.
    @Test func queryBadLimitRejected() {
        let out = ChordApp.dispatch(["query", "--recent-fires", "--limit", "abc"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("--limit needs a positive integer") == true)
    }

    /// A `-`-leading limit is taken verbatim by CLIKit's `.value` arity
    /// (not mistaken for a flag — the D0 hazard), then rejected as
    /// non-positive by the runner.
    @Test func queryNegativeLimitRejected() {
        let out = ChordApp.dispatch(["query", "--recent-fires", "--limit", "-3"])
        #expect(out?.exitCode == 2)
        #expect(out?.stderr?.contains("got '-3'") == true)
    }

    /// With no daemon listening, a query exits 3 (same precondition
    /// shape as the daemon control verbs). Skipped on a host where the
    /// query socket exists (a daemon may be live and would answer 0).
    @Test(.disabled(if: querySocketExists(),
                    "host has the query socket — a daemon may answer"))
    func queryWithoutDaemonReportsExit3() {
        let out = ChordApp.dispatch(["query", "--status"])
        #expect(out?.exitCode == 3)
        #expect(out?.stderr == "chord: no daemon running\n")
    }

    /// A well-formed `--recent-fires --limit N` parses past validation —
    /// the only failure left is "no daemon" (exit 3), never a usage
    /// error (exit 2).
    @Test func queryValidLimitIsNotAUsageError() {
        let out = ChordApp.dispatch(["query", "--recent-fires", "--limit", "10"])
        #expect(out?.exitCode != 2, "a valid --limit must not be a usage error")
    }

    // MARK: - SubcommandOutcome conveniences

    @Test func outcomeOkAddsTrailingNewline() {
        let out = ChordApp.SubcommandOutcome.ok("hello")
        #expect(out.exitCode == 0)
        #expect(out.stdout == "hello\n")
        #expect(out.stderr == nil)
    }

    @Test func outcomeFailAddsTrailingNewline() {
        let out = ChordApp.SubcommandOutcome.fail(7, stderr: "bad")
        #expect(out.exitCode == 7)
        #expect(out.stdout == nil)
        #expect(out.stderr == "bad\n")
    }

    @Test func outcomeCodeNoOutput() {
        let out = ChordApp.SubcommandOutcome.code(42)
        #expect(out.exitCode == 42)
        #expect(out.stdout == nil)
        #expect(out.stderr == nil)
    }
}

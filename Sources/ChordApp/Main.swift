import AppKit
import ChordAdapterMacOS
import ChordCore
import CLIKit
import Foundation

/// `@main enum ChordApp` (not a top-level `main.swift`) — keeps
/// `@testable import ChordApp` working from XCTest once tests of
/// the CLI land. Same trap stroke / facet / ws-tabs documented.
@main
enum ChordApp {
    @MainActor
    static func main() {
        // Debug is env-var-triggered (run.sh sets CHORD_DEBUG=1) — there
        // is no `--debug` flag, so a brew / raw `open Chord.app` launch
        // stays quiet by default.
        Log.debugMode = ProcessInfo.processInfo.environment["CHORD_DEBUG"] != nil

        let args = Array(CommandLine.arguments.dropFirst())

        // Bare `chord` runs the daemon. Every other invocation is a
        // yabai-style `chord <domain> --<verb> [--modifier …]` control
        // command; `dispatch` returns the outcome and exit() is applied
        // at exactly one site (`applyOutcome`), so the whole CLI surface
        // stays unit-testable. nil means "no CLI command — run the server".
        if let outcome = dispatch(args) {
            applyOutcome(outcome)
        }
        runServer()
    }

    // MARK: - subcommand dispatch (#7 + #2)

    /// Result of a subcommand invocation. `stdout` / `stderr` are
    /// written verbatim by `applyOutcome` — handlers are responsible
    /// for trailing newlines (mirrors `print` vs `print(terminator:)`).
    /// Centralising exit() lets the dispatch be tested without
    /// hijacking the process.
    struct SubcommandOutcome {
        var exitCode: Int32
        var stdout: String? = nil
        var stderr: String? = nil

        /// stdout terminated with `\n`, exit 0.
        static func ok(_ line: String? = nil) -> Self {
            .init(exitCode: 0, stdout: line.map { $0 + "\n" })
        }
        /// stderr terminated with `\n`, custom exit code.
        static func fail(_ code: Int32, stderr msg: String) -> Self {
            .init(exitCode: code, stderr: msg + "\n")
        }
        /// Pass-through for handlers that already printed via
        /// Swift's `print(...)` (runValidate / runList / runDoctor
        /// / runResign / runWatch all do this — their output is
        /// streaming or schema-shaped).
        static func code(_ n: Int32) -> Self {
            .init(exitCode: n)
        }
    }

    /// A domain's verb table: each verb flag → the modifier flags it
    /// honours. CLIKit tokenizes argv (loud unknown-flag reject + a
    /// nearest-match hint + the `-h`/`-V` carve-out); chord keeps the
    /// one-verb-per-domain rule and the "this modifier has no effect on
    /// this verb" rejection (no silent no-op) — the D4 line: mechanism
    /// in sill, policy in the app.
    @MainActor
    private static let configVerbs: [String: [String]] = [
        "--validate": ["--strict", "--json"],
        "--show":     ["--json", "--include-dropped"],   // was --list
        "--doctor":   [],
    ]
    @MainActor
    private static let daemonVerbs: [String: [String]] = [
        "--reload": ["--dry-run"],
        "--show":   [],            // was --status
        "--quit":   [],
        "--pause":  [],
        "--resume": [],
        "--toggle": [],
        "--watch":  [],
        "--resign": [],
    ]

    /// Top-level dispatch. Peels the domain noun and routes to its verb
    /// table. Returns nil ONLY for bare `chord` (→ server mode); every
    /// other argv yields an outcome (help / version, a domain command,
    /// or a loud usage error). Unit-testable: no exit(), no child spawn.
    @MainActor
    static func dispatch(_ args: [String]) -> SubcommandOutcome? {
        guard let domain = args.first else { return nil }   // bare chord → server
        let rest = Array(args.dropFirst())
        switch domain {
        case "--help", "-h":    return .ok(helpText())
        case "--version", "-V": return .ok("chord \(ChordVersion.current)")
        case "config": return dispatchDomain("config", rest, configVerbs, runConfig)
        case "daemon": return dispatchDomain("daemon", rest, daemonVerbs, runDaemon)
        default:
            // A `-`-leading first token is almost always an old flat flag
            // (`chord --validate`) — point at the new domain home loudly
            // instead of a bare "unknown command".
            if domain.hasPrefix("-") {
                return .fail(2, stderr: "chord: flags now live under a domain — "
                    + "e.g. `chord config --validate`, `chord daemon --reload`. "
                    + "Got '\(domain)'. See --help.")
            }
            return .fail(2, stderr: "chord: unknown command '\(domain)'. "
                + "Domains: config daemon (or bare `chord` to run the daemon). "
                + "See --help.")
        }
    }

    /// Tokenize `argv` against a domain's verb table (CLIKit), require
    /// exactly one verb, reject any modifier the chosen verb doesn't
    /// honour (loud — no silent no-op), then run it. Every failure maps
    /// to a `SubcommandOutcome` (exit 2) rather than `CLIKit.die`, so the
    /// dispatch stays testable (chord's single-exit-site invariant).
    @MainActor
    private static func dispatchDomain(
        _ domain: String,
        _ argv: [String],
        _ verbs: [String: [String]],
        _ run: @MainActor (String, CLIKit.Invocation) -> SubcommandOutcome
    ) -> SubcommandOutcome {
        // Every verb + every modifier is a recognised boolean flag, so
        // CLIKit catches unknown flags (with a nearest-match hint); chord
        // owns the verb-selection + modifier-applicability policy below.
        var arity: [String: CLIKit.Arity] = [:]
        for v in verbs.keys { arity[v] = .flag }
        for mods in verbs.values { for m in mods { arity[m] = .flag } }
        let inv: CLIKit.Invocation
        do { inv = try CLIKit.parse(argv, spec: CLIKit.Spec(arity: arity)) }
        catch let e as CLIKit.ParseError {
            return .fail(2, stderr: "chord: " + e.usageMessage)
        }
        catch { return .fail(2, stderr: "chord: \(error)") }

        let present = inv.names.filter { verbs[$0] != nil }
        guard present.count == 1, let verb = present.first else {
            if present.isEmpty {
                return .fail(2, stderr: "chord: `chord \(domain)` needs a verb: "
                    + verbs.keys.sorted().joined(separator: " ") + ". See --help.")
            }
            return .fail(2, stderr: "chord: `chord \(domain)`: incompatible verbs "
                + present.sorted().joined(separator: " ") + " — pick one. See --help.")
        }
        // Reject a modifier the verb doesn't honour (e.g. `daemon --quit
        // --dry-run`): no silent swallow.
        let allowed = Set([verb] + (verbs[verb] ?? []))
        for name in inv.names where !allowed.contains(name) {
            return .fail(2, stderr:
                "chord: '\(name)' has no effect with \(verb). See --help.")
        }
        return run(verb, inv)
    }

    /// Single exit() site. Writes verbatim to stdout / stderr (no
    /// added newlines — handlers control terminators).
    @MainActor
    private static func applyOutcome(_ outcome: SubcommandOutcome) -> Never {
        if let s = outcome.stdout, !s.isEmpty {
            FileHandle.standardOutput.write(Data(s.utf8))
        }
        if let s = outcome.stderr, !s.isEmpty {
            FileHandle.standardError.write(Data(s.utf8))
        }
        exit(outcome.exitCode)
    }

    // MARK: - domain verb runners (called by dispatchDomain after the
    // verb + its modifiers are validated; thin shims over the runXxx
    // workers further below)

    /// `config` domain — standalone (no daemon contact).
    @MainActor
    private static func runConfig(_ verb: String,
                                  _ inv: CLIKit.Invocation) -> SubcommandOutcome {
        switch verb {
        case "--validate":
            return .code(runValidate(strict: inv.has("--strict"),
                                     json: inv.has("--json")))
        case "--show":   // was `--list`
            return .code(runList(json: inv.has("--json"),
                                 includeDropped: inv.has("--include-dropped")))
        case "--doctor":
            return .code(runDoctor())
        default:
            return .fail(2, stderr: "chord: unreachable config verb \(verb)")
        }
    }

    /// `daemon` domain — lifecycle (post a `Control` notification + wait,
    /// or read the status file). The `Control.*` wire names are unchanged,
    /// so a new CLI drives an old daemon and vice versa.
    @MainActor
    private static func runDaemon(_ verb: String,
                                  _ inv: CLIKit.Invocation) -> SubcommandOutcome {
        switch verb {
        case "--reload":
            if inv.has("--dry-run") { return .code(runReloadDryRun()) }
            return Control.postAndWait(Control.reload)
                ? .ok("chord: reloaded")
                : .fail(3, stderr: "chord: no daemon running")
        case "--quit":   return cmdControl(Control.quit, label: "quit")
        case "--pause":  return cmdControl(Control.pause, label: "paused")
        case "--resume": return cmdControl(Control.resume, label: "resumed")
        case "--toggle": return cmdToggle()
        case "--show":   return cmdStatus()   // was `--status`
        case "--watch":  return .code(runWatch())
        case "--resign": return .code(runResign())
        default:
            return .fail(2, stderr: "chord: unreachable daemon verb \(verb)")
        }
    }

    /// Shared body for `daemon --quit` / `--pause` / `--resume`. Posts a
    /// `Control` notification name (string constant) to the running
    /// daemon and reports either the labelled success ("chord: \(label)")
    /// or "no daemon running" on stderr with exit 3.
    private static func cmdControl(_ message: String,
                                   label: String) -> SubcommandOutcome {
        if Control.postAndWait(message) {
            return .ok("chord: \(label)")
        }
        return .fail(3, stderr: "chord: no daemon running")
    }

    /// `daemon --toggle` reads the last status line and flips paused ↔
    /// resumed. The daemon writes "paused bindings=N" /
    /// "resumed bindings=N" / "fired …" etc.; a line that starts
    /// with "paused" (with optional leading timestamp/tab) is the
    /// only signal of paused state, since `--resume` and `fired`
    /// both overwrite it.
    private static func cmdToggle() -> SubcommandOutcome {
        let status = Control.readStatus() ?? ""
        let isPaused = status.contains("\tpaused ")
                     || status.hasPrefix("paused ")
                     || status.contains("\tpaused\n")
        return cmdControl(isPaused ? Control.resume : Control.pause,
                          label: isPaused ? "resumed" : "paused")
    }

    /// `daemon --show` (was `--status`) writes the verbatim last status
    /// line (no extra newline — the file already includes one when it
    /// has content).
    private static func cmdStatus() -> SubcommandOutcome {
        if let s = Control.readStatus() {
            return SubcommandOutcome(exitCode: 0, stdout: s)
        }
        return .fail(3, stderr: "chord: no status file")
    }

    // MARK: - server
    //
    // Daemon boot. Unlike the CLI subcommands above this is the
    // long-running path; exit() inside runServer is reserved for
    // startup-fatal conditions (no Accessibility grant, Controller
    // refuses to start) and is intentionally NOT routed through
    // applyOutcome — there is no caller to test, and a real
    // app.run() never returns anyway.

    @MainActor
    private static func runServer() {
        if !Permissions.isAccessibilityTrusted() {
            Log.line("startup: accessibility not granted — prompting")
            _ = Permissions.promptForAccessibility()
            fputs(
                "chord: needs Accessibility access. Grant chord in " +
                "System Settings → Privacy & Security → Accessibility, " +
                "then relaunch.\n", stderr)
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // LSUIElement runtime form

        let controller = Controller()
        do {
            try controller.start()
        } catch {
            fputs("chord: failed to start — \(error)\n", stderr)
            exit(1)
        }

        Log.line("ready")
        app.run()
    }

    // MARK: - standalone subcommands

    /// `config --validate` parses `~/.config/chord/config.toml` and prints
    /// a per-config summary.
    ///
    /// Exit codes:
    ///   0 — clean (no warnings, no dropped bindings)
    ///   1 — `--strict` tripped: at least one warning OR drop
    ///   2 — catastrophic (TOML syntax error, IO failure)
    ///
    /// Without `--strict` chord stays "lenient by default" (drops a
    /// bad binding, keeps the rest) — same posture as stroke / facet.
    /// Add `--strict` in CI to make a typo fail the pipeline.
    private static func runValidate(strict: Bool, json: Bool) -> Int32 {
        do {
            let res = try Config.load()
            if json {
                // JSON mode: emit document with `validation` block
                // on stdout, no stderr noise (the JSON has all the
                // info a CI consumer needs). Exit code unchanged.
                let doc = BindingsSchema.makeDocument(
                    from: res, validationStrict: strict)
                let data = try BindingsSchema.encodeJSON(doc)
                if let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
                return doc.validation?.ok == true ? 0 : 1
            }
            for w in res.warnings { print("warning: \(w.message)") }
            let undef = res.warnings.lazy
                .filter { $0.kind == .undefinedActionAlias }
                .count
            print("parsed: \(res.config.bindings.count) bindings, " +
                  "\(res.config.fallbacks.count) fallbacks, " +
                  "\(res.config.actionAliases.count) action-aliases; " +
                  "dropped: \(res.droppedBindings), " +
                  "undefined-action-aliases: \(undef), " +
                  "warnings: \(res.warnings.count)")
            if strict && (res.warnings.count > 0 || res.droppedBindings > 0) {
                fputs("chord: --strict: \(res.warnings.count) warnings, " +
                      "\(res.droppedBindings) dropped — failing.\n", stderr)
                return 1
            }
            return res.droppedBindings == 0 ? 0 : (strict ? 1 : 0)
        } catch {
            if json {
                // Still emit something parseable so CI consumers
                // don't choke on empty stdout. Use a minimal
                // error envelope; the full schema-validation path
                // doesn't fit (we don't have a parse result).
                let err = ["schema": BindingsSchema.version,
                           "error": "\(error)"]
                if let data = try? JSONSerialization.data(
                    withJSONObject: err,
                    options: [.sortedKeys, .prettyPrinted]),
                   let s = String(data: data, encoding: .utf8)
                {
                    print(s)
                }
                return 2
            }
            fputs("chord: \(error)\n", stderr)
            return 2
        }
    }

    /// `chord config --show [--json] [--include-dropped]` (was `--list`)
    ///
    /// Default is a human-readable text table. `--json` emits the
    /// `chord.bindings.v3` schema document on stdout (machine-
    /// readable). `--include-dropped` adds a `DROPPED` section to
    /// the text output or populates `dropped[]` in JSON (it's
    /// populated regardless of the flag, actually — the flag only
    /// controls text display).
    ///
    /// Exit codes:
    ///   0 — listed successfully
    ///   2 — catastrophic (TOML syntax / IO failure)
    private static func runList(json: Bool, includeDropped: Bool) -> Int32 {
        do {
            let res = try Config.load()
            if json {
                let doc = BindingsSchema.makeDocument(from: res)
                let data = try BindingsSchema.encodeJSON(doc)
                if let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
            } else {
                printListText(res, includeDropped: includeDropped)
            }
            return 0
        } catch {
            fputs("chord: \(error)\n", stderr)
            return 2
        }
    }

    /// Plain-text rendering of the parse result. Same information
    /// as `--list --json`, formatted for a human terminal.
    private static func printListText(_ res: Config.ParseResult,
                                      includeDropped: Bool) {
        if let p = res.sourcePath { print("source: \(p)") }
        print("options:")
        print("  passthrough_unmatched: \(res.config.options.passthroughUnmatched)")
        print("  exclude_apps: \(res.config.options.excludeApps)")
        if !res.config.actionAliases.isEmpty {
            print("action-aliases (\(res.config.actionAliases.count)):")
            for k in res.config.actionAliases.keys.sorted() {
                print("  @\(k) → \(res.config.actionAliases[k] ?? "")")
            }
        }
        printBindingSection("bindings", rows: res.config.bindings)
        if !res.config.fallbacks.isEmpty {
            printBindingSection("fallbacks", rows: res.config.fallbacks)
        }
        if includeDropped && !res.warnings.isEmpty {
            print("dropped / warnings (\(res.warnings.count)):")
            for w in res.warnings {
                let lineTag = w.sourceLine.map { ":\($0)" } ?? ""
                print("  [\(w.kind.rawValue)\(lineTag)] \(w.message)")
            }
        }
    }

    private static func printBindingSection(_ label: String,
                                            rows: [Binding]) {
        print("\(label) (\(rows.count)):")
        for b in rows {
            let lineTag = b.sourceLine.map { ":L\($0)" } ?? ""
            let appsTag = b.apps.map { " apps=\($0)" } ?? ""
            let actionDesc: String
            switch b.action {
            case .keys: actionDesc = "keys → \(b.actionRaw ?? "")"
            case .shell:
                let aliasTag = b.aliasName.map { " (alias @\($0))" } ?? ""
                actionDesc = "shell → \(b.actionRaw ?? "")\(aliasTag)"
            case .noop: actionDesc = "noop"
            case .setVariable(let n, let v):
                actionDesc = "set-variable → \(n)=\(v)"
            case .toggleVariable(let n):
                actionDesc = "toggle-variable → \(n)"
            }
            print("  \(b.name)\(lineTag)")
            print("    input:  \(b.inputRaw)")
            print("    action: \(actionDesc)\(appsTag)")
            for extra in b.extraDownActions {
                if case .keys(let mods, let code) = extra {
                    print("    + keys: \(describeKeys(mods, code))")
                }
            }
        }
    }

    /// Human-readable form of a chained `.keys` action for `config --show`
    /// text. Collapses L/R sides to the logical modifier — the plain
    /// output is for humans; the JSON wire form carries the exact bits.
    private static func describeKeys(_ mods: Modifiers,
                                     _ code: UInt16) -> String {
        var parts: [String] = []
        if mods.contains(.cmd) || mods.contains(.lcmd)
            || mods.contains(.rcmd) { parts.append("cmd") }
        if mods.contains(.opt) || mods.contains(.lopt)
            || mods.contains(.ropt) { parts.append("opt") }
        if mods.contains(.ctrl) || mods.contains(.lctrl)
            || mods.contains(.rctrl) { parts.append("ctrl") }
        if mods.contains(.shift) || mods.contains(.lshift)
            || mods.contains(.rshift) { parts.append("shift") }
        if mods.contains(.fn) { parts.append("fn") }
        let key = KeyCodes.name(forCode: code)
        return parts.isEmpty ? key
            : parts.joined(separator: " + ") + " - " + key
    }

    /// `chord daemon --reload --dry-run` parses the on-disk config.toml
    /// and diffs it against the daemon's last-loaded snapshot
    /// (written by `Controller.loadConfig` to
    /// [BindingsSchema.snapshotPath]). NO IPC, NO daemon state
    /// change — the actual reload only happens on a bare
    /// `chord daemon --reload`.
    ///
    /// Diff granularity is name-keyed: a binding whose name exists
    /// on both sides but whose semantic shape (input / apps /
    /// action) differs is "changed"; a name that only appears on
    /// one side is "added" / "removed". Line shifts due to inserts
    /// elsewhere in the file are deliberately ignored.
    ///
    /// Exit codes:
    ///   0 — diff printed (clean or otherwise)
    ///   2 — catastrophic (TOML syntax / IO failure)
    private static func runReloadDryRun() -> Int32 {
        do {
            let newRes = try Config.load()
            let newDoc = BindingsSchema.makeDocument(from: newRes)
            let oldDoc = loadSnapshot()
            let diff = BindingsSchema.diff(old: oldDoc, new: newDoc)
            printReloadDiff(diff, snapshotPresent: oldDoc != nil)
            return 0
        } catch {
            fputs("chord: \(error)\n", stderr)
            return 2
        }
    }

    private static func loadSnapshot() -> BindingsSchema.Document? {
        let url = URL(fileURLWithPath: BindingsSchema.snapshotPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(
            BindingsSchema.Document.self, from: data)
    }

    private static func printReloadDiff(_ diff: BindingsSchema.Diff,
                                        snapshotPresent: Bool) {
        if !snapshotPresent {
            print("note: no snapshot at \(BindingsSchema.snapshotPath) " +
                  "— treating every binding as added (start the " +
                  "daemon once to populate the snapshot for future dry-runs).")
            print("")
        }
        if diff.isClean {
            print("no changes — `chord daemon --reload` would be a no-op")
            return
        }

        printDiffBucket(label: "bindings",
                        added: diff.addedBindings,
                        removed: diff.removedBindings,
                        changed: diff.changedBindings,
                        unchanged: diff.unchangedBindingCount)
        if !diff.addedFallbacks.isEmpty
            || !diff.removedFallbacks.isEmpty
            || !diff.changedFallbacks.isEmpty
            || diff.unchangedFallbackCount > 0
        {
            print("")
            printDiffBucket(label: "fallbacks",
                            added: diff.addedFallbacks,
                            removed: diff.removedFallbacks,
                            changed: diff.changedFallbacks,
                            unchanged: diff.unchangedFallbackCount)
        }
        if !diff.actionAliasesAdded.isEmpty
            || !diff.actionAliasesRemoved.isEmpty
            || !diff.actionAliasesChanged.isEmpty
        {
            print("")
            print("action-aliases:")
            for k in diff.actionAliasesAdded.keys.sorted() {
                print("  + @\(k) → \(diff.actionAliasesAdded[k] ?? "")")
            }
            for k in diff.actionAliasesRemoved.keys.sorted() {
                print("  - @\(k) → \(diff.actionAliasesRemoved[k] ?? "")")
            }
            for c in diff.actionAliasesChanged.sorted(by: { $0.name < $1.name }) {
                print("  ~ @\(c.name): \(c.oldBody) → \(c.newBody)")
            }
        }
    }

    private static func printDiffBucket(
        label: String,
        added: [BindingsSchema.WireBinding],
        removed: [BindingsSchema.WireBinding],
        changed: [BindingsSchema.Diff.Change],
        unchanged: Int
    ) {
        let totals = "+\(added.count) / -\(removed.count) / " +
                     "~\(changed.count) / =\(unchanged)"
        print("\(label) (\(totals)):")
        for b in added {
            print("  + \(b.name)")
            print("      input:  \(b.input.raw)")
            print("      action: \(describe(b.action))")
            for extra in b.extraActions ?? [] {
                print("      + also: \(describe(extra))")
            }
        }
        for b in removed {
            print("  - \(b.name)")
        }
        for c in changed {
            print("  ~ \(c.new.name)")
            if c.old.input.raw != c.new.input.raw {
                print("      input:  \(c.old.input.raw) → \(c.new.input.raw)")
            }
            if c.old.action != c.new.action {
                print("      action: \(describe(c.old.action)) → " +
                      "\(describe(c.new.action))")
            }
            if c.old.extraActions != c.new.extraActions {
                func fmt(_ xs: [BindingsSchema.WireAction]?) -> String {
                    let s = (xs ?? []).map(describe).joined(separator: ", ")
                    return s.isEmpty ? "—" : s
                }
                print("      +also:  \(fmt(c.old.extraActions)) → " +
                      "\(fmt(c.new.extraActions))")
            }
            if c.old.apps != c.new.apps {
                let oldApps = c.old.apps.map { "\($0)" } ?? "nil"
                let newApps = c.new.apps.map { "\($0)" } ?? "nil"
                print("      apps:   \(oldApps) → \(newApps)")
            }
        }
    }

    private static func describe(_ action: BindingsSchema.WireAction)
        -> String
    {
        switch action.kind {
        case "keys":
            if let raw = action.raw, !raw.isEmpty { return "keys \(raw)" }
            // Extras / on-up actions carry no raw string; rebuild a
            // readable form from the canonical modifier + key fields.
            let mods = (action.modifiers ?? []).joined(separator: " + ")
            let key = action.key?.name ?? ""
            return mods.isEmpty ? "keys \(key)" : "keys \(mods) - \(key)"
        case "shell":
            let aliasTag = action.alias.map { " (alias @\($0))" } ?? ""
            return "shell \(action.command ?? "")\(aliasTag)"
        case "noop":  return "noop"
        default:      return action.kind
        }
    }

    /// `chord daemon --resign` re-signs the installed Chord.app with the
    /// persistent `chord-dev` self-signed identity and restarts the
    /// daemon. Necessary after every `brew install` / `brew upgrade
    /// chord`, because Homebrew's build sandbox blocks the in-formula
    /// `setup-signing-cert.sh` from touching the user's login
    /// keychain — install falls back to ad-hoc signing and TCC
    /// re-prompts for Accessibility on every upgrade.
    ///
    /// Detection order for the installed Chord.app:
    ///   1. /opt/homebrew/Cellar/chord/<latest>/Chord.app  (brew)
    ///   2. /Applications/Chord.app                         (manual)
    ///   3. $HOME/Applications/Chord.app                    (user)
    ///
    /// Exit codes:
    ///   0 — re-signed (and restart attempted)
    ///   1 — codesign failed
    ///   2 — no Chord.app found in any expected location
    /// `chord daemon --watch` — live per-event trace (chord 0.9.0+).
    /// Truncates `/tmp/chord-watch.log` (= "subscribe" signal) and
    /// then `tail -F`s it to stderr. The running daemon emits one
    /// line per event while the file exists. Exit on Ctrl-C; the
    /// file is left behind so a subsequent `chord daemon --watch` keeps
    /// receiving lines. To stop the daemon from writing, the user
    /// can `rm /tmp/chord-watch.log`.
    ///
    /// Exit codes:
    ///   0 — clean exit (Ctrl-C, tail terminated)
    ///   1 — couldn't spawn `tail` / filesystem error
    private static func runWatch() -> Int32 {
        let path = Log.watchPath
        // Truncate / create the file. Daemon checks existence on each
        // event; presence is enough to enable per-event logging.
        guard FileManager.default.createFile(atPath: path, contents: nil)
        else {
            fputs("chord: --watch: cannot create \(path)\n", stderr)
            return 1
        }
        fputs("chord: --watch — tailing \(path) (Ctrl-C to exit; " +
              "rm the file to silence the daemon)\n", stderr)
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        // `-F` follows by name (handles truncate / rotate), `-n0`
        // suppresses the historical lines so the watch starts from
        // the moment the user invoked it.
        tail.arguments = ["-F", "-n", "0", path]
        tail.standardOutput = FileHandle.standardError
        tail.standardError = FileHandle.standardError
        do {
            try tail.run()
            tail.waitUntilExit()
        } catch {
            fputs("chord: --watch: failed to spawn tail — \(error)\n", stderr)
            return 1
        }
        return 0
    }

    ///   3 — chord-dev identity missing from the login keychain
    ///       (user needs to run setup-signing-cert.sh once)
    private static func runResign() -> Int32 {
        guard let appPath = findChordApp() else {
            fputs("chord: no Chord.app found at /opt/homebrew/Cellar/chord/*/, " +
                  "/Applications, or ~/Applications.\n" +
                  "       install via `brew install akira-toriyama/tap/chord` " +
                  "or `./scripts/install-launchagent.sh`.\n", stderr)
            return 2
        }
        print("chord: detected Chord.app at \(appPath)")

        let identity = "chord-dev"
        guard hasSigningIdentity(identity) else {
            fputs("chord: no '\(identity)' identity in your login keychain.\n" +
                  "       run once:\n" +
                  "         \(setupCertHint())\n" +
                  "         chord daemon --resign\n", stderr)
            return 3
        }

        print("chord: signing with identity '\(identity)'")
        let codesignExit = runProcess(
            "/usr/bin/codesign",
            args: ["--force", "--sign", identity, appPath])
        guard codesignExit == 0 else {
            fputs("chord: codesign failed (exit \(codesignExit))\n", stderr)
            return 1
        }

        // Restart the daemon. Try brew services first (the canonical
        // path for brew installs), fall back to a launchctl kickstart
        // on the LaunchAgent label. Either failure is non-fatal — the
        // re-sign itself already succeeded.
        print("chord: restarting daemon")
        let brewExit = runProcess(
            "/opt/homebrew/bin/brew",
            args: ["services", "restart", "chord"],
            captureOutput: true)
        if brewExit == 0 {
            print("chord: restarted via `brew services restart chord`")
            return 0
        }
        for label in ["homebrew.mxcl.chord", "com.chord.chord"] {
            let kick = runProcess(
                "/bin/launchctl",
                args: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
                captureOutput: true)
            if kick == 0 {
                print("chord: restarted via `launchctl kickstart \(label)`")
                return 0
            }
        }
        fputs("chord: re-signed, but couldn't restart the daemon — start it manually.\n",
              stderr)
        return 0
    }

    /// Pick the first existing Chord.app from the canonical install
    /// locations. The brew Cellar (which carries the live binary) is
    /// preferred over manual /Applications copies.
    private static func findChordApp() -> String? {
        let cellar = "/opt/homebrew/Cellar/chord"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            // `.numeric` makes "1.10.0" > "1.2.0" — a plain string
            // sort would silently pick the older 1.2.0 as "latest"
            // once a 1.10 series ships.
            let sorted = versions.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedDescending
            }
            for v in sorted {
                let p = "\(cellar)/\(v)/Chord.app"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        for candidate in [
            "/Applications/Chord.app",
            "\(NSHomeDirectory())/Applications/Chord.app",
        ] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Untrusted self-signed certs don't appear in `find-identity`
    /// (that filter lists trusted identities only). Use
    /// `find-certificate` which surfaces untrusted entries too.
    private static func hasSigningIdentity(_ name: String) -> Bool {
        runProcess(
            "/usr/bin/security",
            args: ["find-certificate", "-c", name,
                   "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"],
            captureOutput: true
        ) == 0
    }

    /// Best-effort guess at where `setup-signing-cert.sh` lives on
    /// the user's machine. brew installs ship it under
    /// `share/chord/`, dev installs have it at the repo root.
    private static func setupCertHint() -> String {
        let brewShared = "/opt/homebrew/share/chord/setup-signing-cert.sh"
        if FileManager.default.fileExists(atPath: brewShared) {
            return brewShared
        }
        return "./setup-signing-cert.sh"
    }

    /// Spawn + wait. Returns the child's exit code on completion,
    /// or `-1` when `Process.run()` itself failed (executable not
    /// found, permission denied, etc.) — the catch path also emits
    /// a stderr line so the caller's generic "exit -1" message
    /// isn't the only signal.
    @discardableResult
    private static func runProcess(_ executable: String,
                                   args: [String],
                                   captureOutput: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if captureOutput {
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            fputs("chord: couldn't launch \(executable): \(error)\n", stderr)
            return -1
        }
    }

    private static func runDoctor() -> Int32 {
        var bad = false
        let ax = Permissions.isAccessibilityTrusted()
        print("accessibility: \(ax ? "ok" : "NOT GRANTED")")
        if !ax { bad = true }

        let cfgPath = ChordConfig.path
        let cfgPresent = FileManager.default.fileExists(atPath: cfgPath)
        print("config: \(cfgPath) — " +
              (cfgPresent ? "present" : "MISSING"))
        if let res = try? Config.load() {
            print("bindings: \(res.config.bindings.count) loaded, " +
                  "\(res.config.fallbacks.count) fallbacks, " +
                  "\(res.config.actionAliases.count) action-aliases, " +
                  "\(res.droppedBindings) dropped")
            // The shipped template is all-commented by design — a
            // brand-new install would otherwise look broken when
            // --doctor reports `bindings: 0 loaded`. Surface the
            // expected next step instead of letting the user guess.
            if cfgPresent && res.config.bindings.count == 0
                && res.config.fallbacks.count == 0
                && res.droppedBindings == 0
            {
                print("note: config has no active bindings — the " +
                      "shipped template is all-commented. Uncomment " +
                      "patterns in \(cfgPath) and run `chord daemon --reload`.")
            }
            if res.droppedBindings > 0 { bad = true }
        }

        let status = Control.readStatus() ?? ""
        print("daemon: \(status.isEmpty ? "not running" : "running")")
        return bad ? 1 : 0
    }

    private static func helpText() -> String {
        """
        chord — global keyboard + mouse hotkey daemon for macOS.

        USAGE
          chord                              run the daemon (default)
          chord <domain> --<verb> [--mod …]  one-shot control command

        config — settings (standalone, no daemon required)
          chord config --validate           parse config.toml; exit 0 on clean
          chord config --validate --strict  warnings + drops fail with exit 1
          chord config --validate --json    chord.bindings.v3 doc + validation block
          chord config --show               human-readable parsed config (was --list)
          chord config --show --json        machine-readable (chord.bindings.v3)
          chord config --show --include-dropped   also list dropped bindings
          chord config --doctor             report Accessibility / config / daemon

        daemon — lifecycle (need a running daemon; exit 3 if none)
          chord daemon --reload             tell the running daemon to reload config
          chord daemon --reload --dry-run   preview what `--reload` would change
          chord daemon --quit               tell the running daemon to exit
          chord daemon --pause              suspend all bindings (passthrough mode)
          chord daemon --resume             re-enable bindings
          chord daemon --toggle             flip paused ↔ resumed (handy as a hotkey)
          chord daemon --show               print the last status line (was --status)
          chord daemon --watch              live per-event trace (subscribes via
                                              /tmp/chord-watch.log; Ctrl-C to exit)
          chord daemon --resign             re-sign Chord.app with chord-dev + restart
                                              (run once after `brew install` / upgrade)

          chord --help, -h                  this text
          chord --version, -V               print version

        Each domain takes exactly one verb; combining verbs or using a flag
        outside its domain exits 2 (an unknown flag prints a "did you mean …?"
        hint). No deprecation shim — the old flat flags (`chord --validate`,
        `chord --reload`, …) now exit 2 and point at the new domain.

        EXIT CODES
          0   success
          1   config --validate --strict tripped (warnings / dropped bindings)
          2   usage / bad flag
          3   daemon precondition: a daemon command with no daemon running

        CONFIG
          \(ChordConfig.path)
          See https://github.com/akira-toriyama/chord
        """
    }
}

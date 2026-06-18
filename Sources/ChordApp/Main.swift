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
        "--validate":    ["--strict", "--json"],
        "--show":        ["--json", "--include-dropped"],   // was --list
        "--doctor":      [],
        "--emit-schema": [],
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
    /// `query` domain — read-only daemon state over the AF_UNIX query
    /// socket (exit 3 if no daemon). Output is always JSON (chord.query.v1);
    /// the domain exists to export machine state, so there's no `--json`
    /// modifier. `--recent-fires --limit N` is chord's one value-taking
    /// modifier (declared in `queryValueFlags`); every other flag is a
    /// bare boolean.
    @MainActor
    private static let queryVerbs: [String: [String]] = [
        "--status":          [],
        "--vars":            [],
        "--loaded-bindings": [],
        "--recent-fires":    ["--limit"],
    ]
    /// Modifiers that consume a following value (CLIKit `.value` arity)
    /// rather than being bare booleans. Verbatim consumption (signed /
    /// `-`-leading OK) — solves the D0 hazard for e.g. a future negative
    /// arg. Today: only `query --recent-fires --limit N`.
    private static let queryValueFlags: Set<String> = ["--limit"]

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
        case "query":  return dispatchDomain("query", rest, queryVerbs, runQuery,
                                             valueFlags: queryValueFlags)
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
                + "Domains: config daemon query (or bare `chord` to run the daemon). "
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
        _ run: @MainActor (String, CLIKit.Invocation) -> SubcommandOutcome,
        valueFlags: Set<String> = []
    ) -> SubcommandOutcome {
        // Every verb is a boolean flag; a modifier is `.value` (consumes
        // the next token verbatim) iff it's in `valueFlags`, else a bare
        // boolean. CLIKit catches unknown flags (with a nearest-match
        // hint); chord owns the verb-selection + modifier-applicability
        // policy below.
        var arity: [String: CLIKit.Arity] = [:]
        for v in verbs.keys { arity[v] = .flag }
        for mods in verbs.values {
            for m in mods { arity[m] = valueFlags.contains(m) ? .value : .flag }
        }
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
        case "--emit-schema":
            return .code(runEmitSchema())
        default:
            return .fail(2, stderr: "chord: unreachable config verb \(verb)")
        }
    }

    /// `chord config --emit-schema` — print the config.toml INPUT JSON Schema
    /// (Draft-07) for taplo editor completion. Generated from
    /// `ChordConfigSchema` (the chord-local descriptor). Stateless: no daemon
    /// contact, no config read. DISTINCT from `config --show --json`, which
    /// emits the chord.bindings.v3 parse-OUTPUT wire format.
    /// Regenerate the committed copy: `chord config --emit-schema > config.schema.json`.
    private static func runEmitSchema() -> Int32 {
        // No trailing newline (terminator: "") so `… > config.schema.json`
        // writes the schema byte-exact, matching the drift guard + siblings.
        print(ChordConfigSchema.jsonSchema, terminator: "")
        return 0
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

    /// `query` domain — read-only live state over the AF_UNIX
    /// request/response socket. The verb stem IS the wire endpoint
    /// (`--vars` → `vars`), so CLI and protocol can't drift. Output is
    /// the daemon's JSON reply verbatim (chord.query.v1); exit 3 if no
    /// daemon is listening. DISTINCT from `daemon --show` (the one-line
    /// status file) and `config --show --json` (the parsed-config
    /// OUTPUT) — this is daemon runtime state.
    @MainActor
    private static func runQuery(_ verb: String,
                                 _ inv: CLIKit.Invocation) -> SubcommandOutcome {
        guard let endpoint = QuerySchema.Endpoint(rawValue: String(verb.dropFirst(2)))
        else { return .fail(2, stderr: "chord: unreachable query verb \(verb)") }

        // `--limit` is only declared for `--recent-fires` (dispatchDomain
        // already rejects it elsewhere); validate the value here.
        var limit: Int? = nil
        if let raw = inv.value("--limit") {
            guard let n = Int(raw), n > 0 else {
                return .fail(2, stderr:
                    "chord: --limit needs a positive integer, got '\(raw)'. See --help.")
            }
            limit = n
        }

        guard let reply = Control.query(
            QuerySchema.Request(endpoint: endpoint, limit: limit))
        else { return .fail(3, stderr: "chord: no daemon running") }
        // The daemon's reply already ends with a newline.
        return SubcommandOutcome(exitCode: 0, stdout: reply)
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
        // Best-effort: refresh the config.schema.json sidecar next to the user
        // config so `#:schema ./config.schema.json` resolves for taplo.
        // Idempotent + non-fatal (see ChordConfigSchema.installSchema).
        ChordConfigSchema.installSchema()

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

    private static func runDoctor() -> Int32 {
        var bad = false
        let ax = Permissions.isAccessibilityTrusted()
        print("accessibility: \(ax ? "ok" : "NOT GRANTED")")
        if !ax { bad = true }

        // Advisory only — Input Monitoring is needed solely by the vkey
        // vendor-HID source; the core CGEventTap daemon runs on
        // Accessibility alone. Don't flip `bad` (would break installs
        // that never use v-key bindings).
        let im = Permissions.isInputMonitoringTrusted()
        print("input monitoring: " +
              (im ? "ok" : "not granted (only needed for v-key bindings)"))

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
          chord config --emit-schema        config.toml JSON Schema for editors (Draft-07)

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

        query — read live daemon state as JSON (need a running daemon; exit 3 if none)
          chord query --status              paused / ax-granted / uptime / config-loaded-at
          chord query --vars                current state-variable values
          chord query --loaded-bindings     bindings / fallbacks / alias counts
          chord query --recent-fires        recently fired bindings (newest first)
          chord query --recent-fires --limit N    cap to the N most recent

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
          3   daemon precondition: a daemon / query command with no daemon running

        CONFIG
          \(ChordConfig.path)
          See https://github.com/akira-toriyama/chord
        """
    }
}

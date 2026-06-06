import AppKit
import ChordAdapterMacOS
import ChordCore
import Foundation

/// `@main enum ChordApp` (not a top-level `main.swift`) — keeps
/// `@testable import ChordApp` working from XCTest once tests of
/// the CLI land. Same trap stroke / facet / ws-tabs documented.
@main
enum ChordApp {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        // Standalone + client subcommands: dispatch through the
        // declarative table. The table preserves prior priority
        // order (document order = first-match-wins), and every
        // handler returns a SubcommandOutcome rather than calling
        // exit() itself — exit() lives at exactly one site
        // (applyOutcome) so the dispatch is unit-testable.
        if let outcome = dispatchSubcommand(args) {
            applyOutcome(outcome)
        }

        // Server flags. Debug is env-var-triggered (run.sh sets
        // CHORD_DEBUG=1) — there is no `--debug` flag, so a brew /
        // raw `open Chord.app` launch stays quiet by default.
        Log.debugMode = ProcessInfo.processInfo.environment["CHORD_DEBUG"] != nil

        // Anything unrecognised → exit 2 (Rule of Repair). Modifier
        // flags consumed by a handler above (--strict / --json / …)
        // re-surface here as plain args; they are silently accepted.
        if let outcome = checkUnknownFlags(args) {
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

    /// Declarative subcommand entry. `flags` is any-of; the first
    /// table row whose flag set intersects argv wins.
    struct Subcommand {
        let flags: [String]
        /// Modifier flags this subcommand honours, e.g. `--validate`
        /// reads `--strict` / `--json`. Any modifier flag absent from
        /// this list, when combined with this subcommand, becomes
        /// "has no effect" — reported as exit 2 by `dispatchSubcommand`
        /// rather than silently swallowed. Subcommand flags from
        /// OTHER rows (e.g. `chord --validate --quit`) are tolerated
        /// as priority-losers and not flagged.
        let modifierFlags: [String]
        /// Closure isolation lives on the function type (Swift 6),
        /// not the storage property — Swift 6 rejects `@MainActor
        /// let handler: …` because the synthesised memberwise init
        /// would have to be both nonisolated (struct default) and
        /// MainActor-isolated.
        let handler: @MainActor ([String]) -> SubcommandOutcome
    }

    /// Subcommand registry. Order = priority (matches the previous
    /// if-chain in main()). Edit here, not in main(), to add a flag.
    @MainActor
    private static let subcommands: [Subcommand] = [
        // Standalone (no daemon contact).
        .init(flags: ["--help", "-h"], modifierFlags: [],
              handler: { _ in cmdHelp() }),
        .init(flags: ["--version"], modifierFlags: [],
              handler: { _ in cmdVersion() }),
        .init(flags: ["--validate"], modifierFlags: ["--strict", "--json"],
              handler: cmdValidate),
        .init(flags: ["--list"], modifierFlags: ["--json", "--include-dropped"],
              handler: cmdList),
        .init(flags: ["--doctor"], modifierFlags: [],
              handler: { _ in cmdDoctor() }),
        // Client flags (post + wait + report).
        .init(flags: ["--reload"], modifierFlags: ["--dry-run"],
              handler: cmdReload),
        .init(flags: ["--quit"], modifierFlags: [],
              handler: { _ in cmdControl(Control.quit, label: "quit") }),
        .init(flags: ["--pause"], modifierFlags: [],
              handler: { _ in cmdControl(Control.pause, label: "paused") }),
        .init(flags: ["--resume"], modifierFlags: [],
              handler: { _ in cmdControl(Control.resume, label: "resumed") }),
        .init(flags: ["--toggle"], modifierFlags: [],
              handler: { _ in cmdToggle() }),
        .init(flags: ["--status"], modifierFlags: [],
              handler: { _ in cmdStatus() }),
        .init(flags: ["--resign"], modifierFlags: [],
              handler: { _ in cmdResign() }),
        .init(flags: ["--watch"], modifierFlags: [],
              handler: { _ in cmdWatch() }),
    ]

    /// All declared subcommand flags, used for the "priority-loser"
    /// tolerance in `dispatchSubcommand` (so `chord --validate --quit`
    /// still runs validate without rejecting the unused `--quit`).
    @MainActor
    private static var allSubcommandFlags: Set<String> {
        Set(subcommands.flatMap(\.flags))
    }

    @MainActor
    static func dispatchSubcommand(_ args: [String]) -> SubcommandOutcome? {
        for cmd in subcommands {
            if cmd.flags.contains(where: { args.contains($0) }) {
                // Reject modifier flags that this subcommand doesn't
                // honour (e.g. `chord --quit --json`). Subcommand
                // flags from OTHER rows are tolerated as priority-
                // losers — they re-surface in the same argv and
                // erroring on them would be hostile.
                let accepted = Set(cmd.flags + cmd.modifierFlags)
                    .union(allSubcommandFlags)
                for a in args where !accepted.contains(a) {
                    return .fail(2, stderr:
                        "chord: '\(a)' has no effect with \(cmd.flags[0]). " +
                        "See --help.")
                }
                return cmd.handler(args)
            }
        }
        return nil
    }

    /// Repair check, server-mode only. Runs when no subcommand
    /// matched: any modifier-like token is suspicious (the daemon
    /// itself takes no flags). All flags accepted by some subcommand
    /// are still rejected here — `chord --strict` alone is a typo.
    static func checkUnknownFlags(_ args: [String]) -> SubcommandOutcome? {
        for a in args {
            return .fail(2, stderr: "chord: unknown flag '\(a)'. See --help.")
        }
        return nil
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

    // MARK: - subcommand handlers (thin wrappers over the runXxx
    // worker functions further below)

    private static func cmdHelp() -> SubcommandOutcome {
        .ok(helpText())
    }

    private static func cmdVersion() -> SubcommandOutcome {
        .ok("chord \(ChordVersion.current)")
    }

    private static func cmdValidate(_ args: [String]) -> SubcommandOutcome {
        .code(runValidate(strict: args.contains("--strict"),
                          json: args.contains("--json")))
    }

    private static func cmdList(_ args: [String]) -> SubcommandOutcome {
        .code(runList(json: args.contains("--json"),
                      includeDropped: args.contains("--include-dropped")))
    }

    @MainActor
    private static func cmdDoctor() -> SubcommandOutcome {
        .code(runDoctor())
    }

    private static func cmdReload(_ args: [String]) -> SubcommandOutcome {
        if args.contains("--dry-run") {
            return .code(runReloadDryRun())
        }
        if Control.postAndWait(Control.reload) {
            return .ok("chord: reloaded")
        }
        return .fail(3, stderr: "chord: no daemon running")
    }

    /// Shared body for `--quit` / `--pause` / `--resume`. Posts a
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

    /// `--toggle` reads the last status line and flips paused ↔
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

    /// `--status` writes the verbatim last status line (no extra
    /// newline — the file already includes one when it has content).
    private static func cmdStatus() -> SubcommandOutcome {
        if let s = Control.readStatus() {
            return SubcommandOutcome(exitCode: 0, stdout: s)
        }
        return .fail(3, stderr: "chord: no status file")
    }

    @MainActor
    private static func cmdResign() -> SubcommandOutcome {
        .code(runResign())
    }

    private static func cmdWatch() -> SubcommandOutcome {
        .code(runWatch())
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

    /// `--validate` parses `~/.config/chord/config.toml` and prints
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

    /// `chord --list [--json] [--include-dropped]`
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

    /// Human-readable form of a chained `.keys` action for `--list`
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

    /// `chord --reload --dry-run` parses the on-disk config.toml
    /// and diffs it against the daemon's last-loaded snapshot
    /// (written by `Controller.loadConfig` to
    /// [BindingsSchema.snapshotPath]). NO IPC, NO daemon state
    /// change — the actual reload only happens on a bare
    /// `chord --reload`.
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
            print("no changes — `chord --reload` would be a no-op")
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

    /// `chord --resign` re-signs the installed Chord.app with the
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
    /// `chord --watch` — live per-event trace (chord 0.9.0+).
    /// Truncates `/tmp/chord-watch.log` (= "subscribe" signal) and
    /// then `tail -F`s it to stderr. The running daemon emits one
    /// line per event while the file exists. Exit on Ctrl-C; the
    /// file is left behind so a subsequent `chord --watch` keeps
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
                  "         chord --resign\n", stderr)
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
                      "patterns in \(cfgPath) and run `chord --reload`.")
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
          chord                run the daemon (default)

          chord --validate          parse config.toml; exit 0 on clean
          chord --validate --strict warnings + drops fail with exit 1
          chord --validate --json   chord.bindings.v3 doc + validation block
          chord --list              human-readable parsed config
          chord --list --json       machine-readable (chord.bindings.v3)
          chord --list --include-dropped   also list dropped bindings
          chord --doctor            report Accessibility / config / daemon
          chord --resign            re-sign Chord.app with chord-dev + restart
                                    (run once after `brew install` / upgrade)
          chord --reload       tell the running daemon to reload config
          chord --reload --dry-run   preview what `--reload` would change
          chord --quit         tell the running daemon to exit
          chord --pause        suspend all bindings (passthrough mode)
          chord --resume       re-enable bindings
          chord --toggle       flip paused ↔ resumed (handy as a hotkey)
          chord --status       print the last status line
          chord --watch        live per-event trace (subscribes via
                               /tmp/chord-watch.log; Ctrl-C to exit)

          chord --help         this text
          chord --version      print version

        CONFIG
          \(ChordConfig.path)
          See https://github.com/akira-toriyama/chord
        """
    }
}

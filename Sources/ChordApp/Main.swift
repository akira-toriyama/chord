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

        // Standalone flags first (each prints + exits).
        if args.contains("--help") || args.contains("-h") {
            printHelp(); exit(0)
        }
        if args.contains("--version") {
            print("chord 0.6.0"); exit(0)
        }
        if args.contains("--validate") {
            exit(runValidate(strict: args.contains("--strict"),
                             json: args.contains("--json")))
        }
        if args.contains("--list") {
            exit(runList(json: args.contains("--json"),
                         includeDropped: args.contains("--include-dropped")))
        }
        if args.contains("--doctor")   { exit(runDoctor()) }

        // Client flags: post + exit.
        if args.contains("--reload") {
            if args.contains("--dry-run") {
                exit(runReloadDryRun())
            }
            let ok = Control.postAndWait(Control.reload)
            if !ok { fputs("chord: no daemon running\n", stderr); exit(3) }
            print("chord: reloaded"); exit(0)
        }
        if args.contains("--quit") {
            let ok = Control.postAndWait(Control.quit)
            if !ok { fputs("chord: no daemon running\n", stderr); exit(3) }
            print("chord: quit"); exit(0)
        }
        if args.contains("--pause") {
            let ok = Control.postAndWait(Control.pause)
            if !ok { fputs("chord: no daemon running\n", stderr); exit(3) }
            print("chord: paused"); exit(0)
        }
        if args.contains("--resume") {
            let ok = Control.postAndWait(Control.resume)
            if !ok { fputs("chord: no daemon running\n", stderr); exit(3) }
            print("chord: resumed"); exit(0)
        }
        if args.contains("--toggle") {
            // Read the most recent status line and infer pause state.
            // The daemon writes "paused bindings=N" / "resumed
            // bindings=N" / "fired …" / "started …" etc.; a line
            // starting with "paused" is the only signal of paused
            // state, since `--resume` and `fired` both overwrite it.
            let status = Control.readStatus() ?? ""
            let isPaused = status.contains("\tpaused ")
                         || status.hasPrefix("paused ")
                         || status.contains("\tpaused\n")
            let cmd = isPaused ? Control.resume : Control.pause
            let label = isPaused ? "resumed" : "paused"
            let ok = Control.postAndWait(cmd)
            if !ok { fputs("chord: no daemon running\n", stderr); exit(3) }
            print("chord: \(label)"); exit(0)
        }
        if args.contains("--status") {
            if let s = Control.readStatus() { print(s, terminator: "") }
            else { fputs("chord: no status file\n", stderr); exit(3) }
            exit(0)
        }
        if args.contains("--resign") {
            exit(runResign())
        }

        // Server flags.
        Log.debugMode = args.contains("--debug")

        // Anything else unrecognised → exit 2 (Rule of Repair).
        for a in args {
            // Flags consumed by handlers above this point may
            // re-appear here for the same invocation (e.g.
            // `--validate --strict`); silently accept them.
            switch a {
            case "--debug",
                 "--strict",
                 "--json",
                 "--include-dropped",
                 "--dry-run":
                continue
            default:
                fputs("chord: unknown flag '\(a)'. See --help.\n", stderr)
                exit(2)
            }
        }

        runServer()
    }

    // MARK: - server

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
            }
            print("  \(b.name)\(lineTag)")
            print("    input:  \(b.inputRaw)")
            print("    action: \(actionDesc)\(appsTag)")
        }
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
        case "keys":  return "keys \(action.raw ?? "")"
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

    private static func printHelp() {
        print("""
        chord — global keyboard + mouse hotkey daemon for macOS.

        USAGE
          chord                run the daemon (default)
          chord --debug        run the daemon with verbose logging

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

          chord --help         this text
          chord --version      print version

        CONFIG
          \(ChordConfig.path)
          See https://github.com/akira-toriyama/chord
        """)
    }
}

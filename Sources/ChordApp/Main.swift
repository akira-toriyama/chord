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
            print("chord 0.3.2"); exit(0)
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
                 "--include-dropped":
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
                .filter { $0.kind == .undefinedAlias }
                .count
            print("parsed: \(res.config.bindings.count) bindings, " +
                  "\(res.config.fallbacks.count) fallbacks, " +
                  "\(res.config.aliases.count) aliases; " +
                  "dropped: \(res.droppedBindings), " +
                  "undefined-aliases: \(undef), " +
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
    /// `chord.bindings.v1` schema document on stdout (machine-
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
        if !res.config.aliases.isEmpty {
            print("aliases (\(res.config.aliases.count)):")
            for k in res.config.aliases.keys.sorted() {
                print("  @\(k) → \(res.config.aliases[k] ?? "")")
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
            }
            print("  \(b.name)\(lineTag)")
            print("    input:  \(b.inputRaw)")
            print("    action: \(actionDesc)\(appsTag)")
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
                  "\(res.config.aliases.count) aliases, " +
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
          chord --validate --json   chord.bindings.v1 doc + validation block
          chord --list              human-readable parsed config
          chord --list --json       machine-readable (chord.bindings.v1)
          chord --list --include-dropped   also list dropped bindings
          chord --doctor            report Accessibility / config / daemon
          chord --reload       tell the running daemon to reload config
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

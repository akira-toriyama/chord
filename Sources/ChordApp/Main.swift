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
            print("chord 0.2.0"); exit(0)
        }
        if args.contains("--validate") {
            exit(runValidate(strict: args.contains("--strict")))
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
            if a == "--debug" { continue }
            fputs("chord: unknown flag '\(a)'. See --help.\n", stderr)
            exit(2)
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
    private static func runValidate(strict: Bool) -> Int32 {
        do {
            let res = try Config.load()
            for w in res.warnings { print("warning: \(w)") }
            let undef = res.warnings.lazy
                .filter { $0.contains("undefined alias") }
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
            fputs("chord: \(error)\n", stderr)
            return 2
        }
    }

    private static func runDoctor() -> Int32 {
        var bad = false
        let ax = Permissions.isAccessibilityTrusted()
        print("accessibility: \(ax ? "ok" : "NOT GRANTED")")
        if !ax { bad = true }

        let cfgPath = ChordConfig.path
        print("config: \(cfgPath) — " +
              (FileManager.default.fileExists(atPath: cfgPath)
               ? "present" : "MISSING"))
        if let res = try? Config.load() {
            print("bindings: \(res.config.bindings.count) loaded, " +
                  "\(res.droppedBindings) dropped")
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

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
            print("chord 0.1.0"); exit(0)
        }
        if args.contains("--validate") { exit(runValidate()) }
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

    private static func runValidate() -> Int32 {
        do {
            let res = try Config.load()
            for w in res.warnings { print("warning: \(w)") }
            print("\(res.config.bindings.count) bindings, " +
                  "\(res.droppedBindings) dropped")
            return res.droppedBindings == 0 ? 0 : 2
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

          chord --validate     parse config.toml; exit 0 on clean
          chord --doctor       report Accessibility / config / daemon
          chord --reload       tell the running daemon to reload config
          chord --quit         tell the running daemon to exit
          chord --status       print the last status line

          chord --help         this text
          chord --version      print version

        CONFIG
          \(ChordConfig.path)
          See https://github.com/akira-toriyama/chord
        """)
    }
}

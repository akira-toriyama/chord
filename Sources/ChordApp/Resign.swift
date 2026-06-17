// Resign.swift — `chord daemon --resign` re-sign + restart flow, plus the
// install-location / signing-identity / subprocess helpers it needs. Split
// out of Main.swift (the CLI-dispatch monolith); an extension on the same
// `ChordApp` enum, same module. Only `runResign` is module-visible (called
// by the daemon dispatch); the helpers stay file-private here.

import Foundation

extension ChordApp {
    static func runResign() -> Int32 {
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
}

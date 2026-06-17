// ReloadDiffPrinter.swift — the `chord daemon --reload --dry-run` diff
// renderer: load the last-loaded snapshot, diff it against the on-disk
// config, and print the added/removed/changed buckets. Split out of
// Main.swift (the CLI-dispatch monolith); an extension on the same
// `ChordApp` enum, same module. Only `runReloadDryRun` is module-visible
// (called by the daemon dispatch); the printers stay file-private here.

import ChordCore
import Foundation

extension ChordApp {
    static func runReloadDryRun() -> Int32 {
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
}

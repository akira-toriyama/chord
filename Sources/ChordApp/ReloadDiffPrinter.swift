// ReloadDiffPrinter.swift — the `chord daemon --reload --dry-run` diff
// renderer: load the last-loaded snapshot, diff it against the on-disk
// config, and print the added/removed/changed buckets. Split out of
// Main.swift (the CLI-dispatch monolith); an extension on the same
// `ChordApp` enum, same module. Only `runReloadDryRun` is module-visible
// (called by the daemon dispatch); the printers stay file-private here.

import ChordCore
import Foundation

extension ChordApp {
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
}

// ReloadDiffPrinter.swift — the `chord daemon --reload --dry-run` diff
// renderer: load the last-loaded snapshot, diff it against the on-disk
// config, and print the added/removed/changed buckets. Split out of
// Main.swift (the CLI-dispatch monolith); an extension on the same
// `ChordApp` enum, same module.
//
// The renderers BUILD a string (`render*`) and `runReloadDryRun` prints
// it. They are `internal` (not `private`) so ChordIntegrationTests can
// assert on the rendered text via `@testable import ChordApp` without
// capturing stdout — every reload-diff dimension is covered by a
// deterministic string assertion.

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
    /// action / condition / hold-while / on-up / passthrough /
    /// repeat / input-source) differs is "changed"; a name that only
    /// appears on one side is "added" / "removed". Line shifts due to
    /// inserts elsewhere in the file are deliberately ignored.
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
            print(renderReloadDiff(diff, snapshotPresent: oldDoc != nil))
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

    /// Renders the whole dry-run diff to a string. Mirrors every
    /// dimension `BindingsSchema.Diff` tracks — bindings, fallbacks,
    /// action-aliases AND input-aliases — so an `isClean == false`
    /// diff can never render as empty (the bug fixed here: an
    /// `[input-aliases]`-only edit used to flip `isClean` while
    /// printing nothing).
    static func renderReloadDiff(_ diff: BindingsSchema.Diff,
                                 snapshotPresent: Bool) -> String {
        var out: [String] = []
        if !snapshotPresent {
            out.append("note: no snapshot at \(BindingsSchema.snapshotPath) " +
                       "— treating every binding as added (start the " +
                       "daemon once to populate the snapshot for future dry-runs).")
            out.append("")
        }
        if diff.isClean {
            out.append("no changes — `chord daemon --reload` would be a no-op")
            return out.joined(separator: "\n")
        }

        out.append(renderDiffBucket(label: "bindings",
                                    added: diff.addedBindings,
                                    removed: diff.removedBindings,
                                    changed: diff.changedBindings,
                                    unchanged: diff.unchangedBindingCount))
        if !diff.addedFallbacks.isEmpty
            || !diff.removedFallbacks.isEmpty
            || !diff.changedFallbacks.isEmpty
            || diff.unchangedFallbackCount > 0
        {
            out.append("")
            out.append(renderDiffBucket(label: "fallbacks",
                                        added: diff.addedFallbacks,
                                        removed: diff.removedFallbacks,
                                        changed: diff.changedFallbacks,
                                        unchanged: diff.unchangedFallbackCount))
        }
        if let block = renderAliasBucket(
            "action-aliases", prefix: "@",
            added: diff.actionAliasesAdded,
            removed: diff.actionAliasesRemoved,
            changed: diff.actionAliasesChanged)
        {
            out.append("")
            out.append(block)
        }
        // input-aliases: `$NAME` modifier-set aliases. Parallel to
        // action-aliases; previously missing here, so an
        // [input-aliases]-only edit showed a misleading empty diff.
        if let block = renderAliasBucket(
            "input-aliases", prefix: "$",
            added: diff.inputAliasesAdded,
            removed: diff.inputAliasesRemoved,
            changed: diff.inputAliasesChanged)
        {
            out.append("")
            out.append(block)
        }
        return out.joined(separator: "\n")
    }

    /// `nil` when the alias bucket has no changes (so the caller can skip
    /// the leading blank line). `prefix` is the reference sigil: `@` for
    /// action-aliases, `$` for input-aliases.
    static func renderAliasBucket(
        _ label: String, prefix: String,
        added: [String: String],
        removed: [String: String],
        changed: [(name: String, oldBody: String, newBody: String)]
    ) -> String? {
        if added.isEmpty && removed.isEmpty && changed.isEmpty { return nil }
        var out: [String] = ["\(label):"]
        for k in added.keys.sorted() {
            out.append("  + \(prefix)\(k) → \(added[k] ?? "")")
        }
        for k in removed.keys.sorted() {
            out.append("  - \(prefix)\(k) → \(removed[k] ?? "")")
        }
        for c in changed.sorted(by: { $0.name < $1.name }) {
            out.append("  ~ \(prefix)\(c.name): \(c.oldBody) → \(c.newBody)")
        }
        return out.joined(separator: "\n")
    }

    static func renderDiffBucket(
        label: String,
        added: [BindingsSchema.WireBinding],
        removed: [BindingsSchema.WireBinding],
        changed: [BindingsSchema.Diff.Change],
        unchanged: Int
    ) -> String {
        var out: [String] = []
        let totals = "+\(added.count) / -\(removed.count) / " +
                     "~\(changed.count) / =\(unchanged)"
        out.append("\(label) (\(totals)):")
        for b in added {
            out.append("  + \(b.name)")
            out.append("      input:  \(b.input.raw)")
            out.append("      action: \(describe(b.action))")
            for extra in b.extraActions ?? [] {
                out.append("      + also: \(describe(extra))")
            }
        }
        for b in removed {
            out.append("  - \(b.name)")
        }
        for c in changed {
            out.append("  ~ \(c.new.name)")
            if c.old.input.raw != c.new.input.raw {
                out.append("      input:  \(c.old.input.raw) → \(c.new.input.raw)")
            }
            if c.old.action != c.new.action {
                out.append("      action: \(describe(c.old.action)) → " +
                           "\(describe(c.new.action))")
            }
            if c.old.extraActions != c.new.extraActions {
                out.append("      +also:  \(describeActions(c.old.extraActions)) → " +
                           "\(describeActions(c.new.extraActions))")
            }
            // Below were silently dropped: a changed binding that only
            // toggled a when-var / hold-while / on-up / etc. rendered as
            // a bare `~ <name>` with no reason. Each dimension that
            // semanticallyEqual compares now has a matching diff line.
            if c.old.condition != c.new.condition {
                out.append("      when:   \(describeCondition(c.old.condition)) → " +
                           "\(describeCondition(c.new.condition))")
            }
            if c.old.holdWhile != c.new.holdWhile {
                out.append("      hold-while: \(describeMods(c.old.holdWhile)) → " +
                           "\(describeMods(c.new.holdWhile))")
            }
            if c.old.holdWhileTimeoutMs != c.new.holdWhileTimeoutMs {
                out.append("      hold-while-timeout: \(describeMs(c.old.holdWhileTimeoutMs)) → " +
                           "\(describeMs(c.new.holdWhileTimeoutMs))")
            }
            if c.old.actionOnUp != c.new.actionOnUp {
                out.append("      on-up:  \(describeOptAction(c.old.actionOnUp)) → " +
                           "\(describeOptAction(c.new.actionOnUp))")
            }
            if c.old.passthrough != c.new.passthrough {
                out.append("      passthrough: \(c.old.passthrough ?? false) → " +
                           "\(c.new.passthrough ?? false)")
            }
            if c.old.repeatStrategy != c.new.repeatStrategy {
                out.append("      repeat: \(c.old.repeatStrategy ?? "fire-each") → " +
                           "\(c.new.repeatStrategy ?? "fire-each")")
            }
            if c.old.inputSource != c.new.inputSource {
                out.append("      input-source: \(describeList(c.old.inputSource)) → " +
                           "\(describeList(c.new.inputSource))")
            }
            if c.old.apps != c.new.apps {
                let oldApps = c.old.apps.map { "\($0)" } ?? "nil"
                let newApps = c.new.apps.map { "\($0)" } ?? "nil"
                out.append("      apps:   \(oldApps) → \(newApps)")
            }
        }
        return out.joined(separator: "\n")
    }

    static func describe(_ action: BindingsSchema.WireAction) -> String {
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
        // set-variable / toggle-variable used to fall through to the
        // bare kind string, dropping the variable name + value that
        // `config --show` (Main.swift) prints. Surface them here too.
        case "set-variable":
            return "set-variable \(action.variable ?? "")=\(action.value ?? 0)"
        case "toggle-variable":
            return "toggle-variable \(action.variable ?? "")"
        default:      return action.kind
        }
    }

    static func describeActions(_ xs: [BindingsSchema.WireAction]?) -> String {
        let s = (xs ?? []).map(describe).joined(separator: ", ")
        return s.isEmpty ? "—" : s
    }

    static func describeOptAction(_ a: BindingsSchema.WireAction?) -> String {
        a.map(describe) ?? "—"
    }

    static func describeCondition(_ c: BindingsSchema.WireCondition?) -> String {
        guard let c = c else { return "—" }
        switch c.kind {
        case "variable":
            return "\(c.variable ?? "?")==\(c.equals ?? 0)"
        case "all":
            return (c.conditions ?? []).map(describeCondition)
                .joined(separator: " && ")
        default:
            return c.kind
        }
    }

    static func describeMods(_ m: [String]?) -> String {
        guard let m = m, !m.isEmpty else { return "—" }
        return m.joined(separator: " + ")
    }

    static func describeMs(_ ms: Int?) -> String {
        ms.map { "\($0)ms" } ?? "—"
    }

    static func describeList(_ xs: [String]?) -> String {
        guard let xs = xs, !xs.isEmpty else { return "—" }
        return xs.joined(separator: ", ")
    }
}

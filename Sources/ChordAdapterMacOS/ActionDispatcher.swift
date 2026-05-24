import AppKit
import ChordCore
import CoreGraphics
import Foundation

/// Executes a matched binding's action. Synthetic key posts are
/// tagged with [EventTap.syntheticUserData] so the tap callback can
/// short-circuit them before they hit the matcher again.
public enum ActionDispatcher {
    /// Run a binding's action. Called synchronously from inside the
    /// tap callback (still fast: shell exec is `Task.detached`'d).
    public static func dispatch(_ binding: Binding) {
        switch binding.action {
        case .noop:
            Log.debug("dispatch.noop: \(binding.name)")
        case .keys(let mods, let code):
            Log.debug("dispatch.keys: \(binding.name) → " +
                      "mods=\(mods.rawValue) code=\(code)")
            postKeys(modifiers: mods, code: code)
        case .shell(let cmd):
            Log.debug("dispatch.shell: \(binding.name) → \(cmd)")
            Task.detached(priority: .userInitiated) {
                ActionDispatcher.runShell(cmd, binding: binding)
            }
        }
    }

    // MARK: - keys

    nonisolated(unsafe) private static let source =
        CGEventSource(stateID: .hidSystemState)

    static func postKeys(modifiers: Modifiers, code: UInt16) {
        let src = source
        let flags = cgFlags(from: modifiers)

        // Posting modifier flag-changes first lets apps see the
        // combined state (cmd+shift+4 needs cmd AND shift held
        // when the 4 lands). Apple's docs recommend "set flags on
        // the keyDown event" — that works for cmd+key but not for
        // cmd+shift+key, so we explicitly raise flag-changes too.
        if let down = CGEvent(keyboardEventSource: src,
                              virtualKey: code, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData,
                                      value: EventTap.syntheticUserData)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src,
                            virtualKey: code, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData,
                                    value: EventTap.syntheticUserData)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func cgFlags(from m: Modifiers) -> CGEventFlags {
        var raw: UInt64 = 0
        // The abstract masks every app's NSEvent surface reads.
        // Set when EITHER the any-side bit OR one of the side-
        // specific bits is requested.
        for cat in SideMaskTable.categories
            where m.contains(cat.any)
               || m.contains(cat.left)
               || m.contains(cat.right)
        {
            raw |= cat.mask.rawValue
        }
        // Device-dependent bits — only set when the binding
        // explicitly asked for a specific side. A plain
        // `action-keys = "cmd - c"` leaves these clear so the
        // receiving app sees "either side cmd" the way the user
        // wrote. The bit↔mask table is shared with
        // EventTap.readModifiers via [SideMaskTable].
        for (bit, mask) in SideMaskTable.entries where m.contains(bit) {
            raw |= mask
        }
        if m.contains(.fn) { raw |= CGEventFlags.maskSecondaryFn.rawValue }
        return CGEventFlags(rawValue: raw)
    }

    // MARK: - shell

    static func runShell(_ command: String, binding: Binding) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", command]
        // Login shell so PATH is the user's interactive PATH
        // (Homebrew, asdf, mise etc. — same fix focusfx documents).
        var env = ProcessInfo.processInfo.environment
        env["CHORD_BINDING_NAME"] = binding.name
        if let id = FrontmostTracker.shared.bundleID {
            env["CHORD_FRONTMOST_BUNDLE_ID"] = id
        }
        proc.environment = env
        do {
            try proc.run()
        } catch {
            Log.line("dispatch.shell error: \(error) — \(command)")
        }
    }
}

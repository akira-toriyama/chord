import ChordAdapterMacOS
import ChordCore
import CoreFoundation
import Foundation

/// `chord config --observe` — interactive input-discovery diagnostic.
///
/// Opens a short-lived CGEventTap (reusing the daemon's
/// `MacOSEventSource`) in **pure passthrough** — the handler always
/// returns `.passthrough`, so nothing is ever consumed — and prints
/// the keycode, mouse button, scroll direction, and **side-specific**
/// modifier mask of each event to stdout until Ctrl-C.
///
/// Why it exists: chord is headless, so there is no other way to learn
/// the raw `CGKeyCode` a non-mapped key emits (for the `keycode-N`
/// escape hatch), or to confirm which side bit (`lctrl` vs `rctrl`) /
/// which mouse button (`side1` vs `side2`) the OS actually reports for
/// a given piece of hardware — the L/R strict-side model and the
/// ULTRA_LL authoring depend on knowing that. It is a standalone
/// `config`-domain diagnostic (same family as `--doctor` /
/// `--emit-schema`): no daemon contact, no config read.
///
/// It requests its own Accessibility grant when run as a separate
/// short-lived process — same prompt the daemon needs.
enum ObserveCommand {

    /// AX-check, then open the tap and stream until Ctrl-C. Returns
    /// 1 when Accessibility isn't granted or the tap can't be created;
    /// otherwise blocks in the run loop (Ctrl-C terminates the process).
    @MainActor
    static func run() -> Int32 {
        guard Permissions.isAccessibilityTrusted() else {
            FileHandle.standardError.write(
                Data(
                    ("chord: observe needs Accessibility access. Grant chord in "
                        + "System Settings → Privacy & Security → Accessibility, then retry.\n")
                        .utf8))
            return 1
        }
        FileHandle.standardError.write(
            Data(
                ("chord: observe — press keys / mouse buttons / scroll to see their "
                    + "codes, sides, and modifiers. Nothing is consumed. Ctrl-C to stop.\n").utf8))

        let source = MacOSEventSource()
        do {
            try source.start { event in
                if let line = ObserveCommand.line(for: event) {
                    print(line)
                    fflush(stdout)  // stream live even when stdout is piped
                }
                return .passthrough  // observe never swallows input
            }
        } catch {
            FileHandle.standardError.write(Data("chord: observe: \(error)\n".utf8))
            return 1
        }
        // Spin the run loop the tap was installed on. Ctrl-C (SIGINT)
        // tears the process down; CFRunLoopRun never returns here, so the
        // trailing `return` is only for totality.
        CFRunLoopRun()
        return 0
    }

    /// Pure formatter: one display line per input event, or `nil` for
    /// events observe deliberately omits (key/mouse releases, synthetic
    /// events we posted, and modifier transitions that leave no modifier
    /// held — release-to-empty noise). Kept separate from `run()` so it
    /// is unit-testable without a live tap.
    static func line(for e: InputEvent) -> String? {
        if e.isSynthetic { return nil }
        let mods = "mods=[\(modString(e.modifiers))]"
        switch e.trigger {
        case .key(let code):
            switch e.kind {
            case .up:
                return nil
            case .modifiersChanged:
                // Show only modifier-DOWN transitions; a release back to
                // no-modifier is noise for discovery.
                return e.modifiers.isEmpty
                    ? nil
                    : "flags      \(mods)"
            case .down:
                let rep = e.isRepeat ? "  (repeat)" : ""
                return "keyDown    key=\(KeyCodes.name(forCode: code))  "
                    + "code=\(code)  \(mods)\(rep)"
            }
        case .mouseButton(let b):
            if e.kind == .up { return nil }
            return "mouseDown   button=\(b) (\(b.rawValue))  \(mods)"
        case .scroll(let d):
            return "scroll      dir=\(d)  \(mods)"
        case .vkey(let id):
            // The CGEventTap source never emits vkeys (those arrive via
            // VKeyHIDSource, which observe doesn't open) — handled for
            // exhaustiveness / forward-safety.
            if e.kind == .up { return nil }
            return "vkey        id=\(id)  \(mods)"
        case .anyKey, .modifiersOnly, .anyVKey:
            // Config/matcher-side wildcards & the modifier-only trigger —
            // never produced as a raw input event by the tap.
            return nil
        }
    }

    /// Render a [Modifiers] mask as its concrete side-specific tokens
    /// (`rctrl`, `lshift`, …) in a stable order — the whole point of
    /// observe is to surface the side bits, so this never collapses to
    /// the logical (`ctrl`) form the way `config --show` text does.
    static func modString(_ m: Modifiers) -> String {
        let pairs: [(Modifiers, String)] = [
            (.lctrl, "lctrl"), (.rctrl, "rctrl"), (.ctrl, "ctrl"),
            (.lopt, "lopt"), (.ropt, "ropt"), (.opt, "opt"),
            (.lshift, "lshift"), (.rshift, "rshift"), (.shift, "shift"),
            (.lcmd, "lcmd"), (.rcmd, "rcmd"), (.cmd, "cmd"),
            (.fn, "fn")
        ]
        let tokens = pairs.filter { m.contains($0.0) }.map(\.1)
        return tokens.isEmpty ? "(none)" : tokens.joined(separator: " + ")
    }
}

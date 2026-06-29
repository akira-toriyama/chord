import ChordCore
import CoreGraphics
import Foundation

/// Single source of truth for the bidirectional mapping between
/// chord's side-specific `Modifiers` bits and the device-dependent
/// `NX_DEVICE*KEYMASK` constants in `IOKit/hidsystem/IOLLEvent.h`.
///
/// [EventTap.readModifiers] uses it to translate **flags → bits**;
/// [ActionDispatcher.cgFlags] uses it to translate **bits → flags**
/// when posting a synthetic key. Keeping the pair in one table
/// means adding a new modifier slot only touches this file.
///
/// The constants are stable and have been the same since the
/// Carbon era — the comments record the original NX_DEVICE name
/// so a grep for the IOKit header lands here.
enum SideMaskTable {
    /// (chord bit, IOLLEvent NX_DEVICE\* hex constant).
    static let entries: [(Modifiers, UInt64)] = [
        (.lcmd, 0x00000008),  // NX_DEVICELCMDKEYMASK
        (.rcmd, 0x00000010),  // NX_DEVICERCMDKEYMASK
        (.lopt, 0x00000020),  // NX_DEVICELALTKEYMASK
        (.ropt, 0x00000040),  // NX_DEVICERALTKEYMASK
        (.lctrl, 0x00000001),  // NX_DEVICELCTLKEYMASK
        (.rctrl, 0x00002000),  // NX_DEVICERCTLKEYMASK
        (.lshift, 0x00000002),  // NX_DEVICELSHIFTKEYMASK
        (.rshift, 0x00000004)  // NX_DEVICERSHIFTKEYMASK
    ]

    /// Per-modifier-category mapping from the abstract `Modifiers`
    /// bit (`.cmd` / `.opt` / `.ctrl` / `.shift`) to its CGEventFlags
    /// counterpart and the two side-specific bits in the same
    /// category. Used both ways:
    ///
    /// * `EventTap.readModifiers`: if the OS posted only the abstract
    ///   mask, default the side to `.left` so any-side bindings still
    ///   fire without spuriously matching strict-left ones.
    /// * `ActionDispatcher.cgFlags`: set the abstract bit whenever
    ///   ANY of (any / left / right) is requested on the binding.
    static let categories:
        [(
            any: Modifiers,
            mask: CGEventFlags,
            left: Modifiers,
            right: Modifiers
        )] = [
            (.cmd, .maskCommand, .lcmd, .rcmd),
            (.opt, .maskAlternate, .lopt, .ropt),
            (.ctrl, .maskControl, .lctrl, .rctrl),
            (.shift, .maskShift, .lshift, .rshift)
        ]
}

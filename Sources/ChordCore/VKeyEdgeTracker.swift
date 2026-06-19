import Foundation

/// Pure press/release edge tracker for vendor-HID v-keys.
///
/// The firmware sends one report per edge: a pressed id `1...255`, or `0`
/// on release. A release report carries no id, so the tracker latches the
/// last-pressed id (`held`, 0 = nothing held) to know which `.up` to emit.
///
/// `events(for:)` is the entire edge contract, lifted out of `Controller`
/// so it is unit-testable in isolation and — by construction — **cannot
/// wedge**: the latch advances to the new selector unconditionally,
/// independent of whatever the caller does with the returned edges (pause,
/// dispatch, IO). That separation is what prevents the held-vkey-during-pause
/// latch-stick regression the vkey adversarial review once found.
///
/// Contract (`held` = currently-latched id):
/// - selector == held         → `[]` (duplicate report / autorepeat), latch unchanged
/// - `0` while holding         → `[.up(held)]`, latch → 0
/// - fresh id, A→B (no `0`)     → `[.up(held), .down(new)]`, latch → new
/// - fresh id while idle        → `[.down(new)]`, latch → new
/// - `0` while idle             → `[]`, latch stays 0
public struct VKeyEdgeTracker: Sendable {
    /// An edge to feed downstream as an `InputEvent` of `.vkey(id)`.
    public struct Edge: Sendable, Equatable {
        public let id: UInt8
        public let kind: EventKind   // .down or .up
        public init(id: UInt8, kind: EventKind) {
            self.id = id
            self.kind = kind
        }
    }

    /// The currently-held vkey id (`0` = nothing held).
    public private(set) var held: UInt8 = 0

    public init() {}

    /// Drop the latch (e.g. on config reload) so no stale `.up` is later
    /// synthesised for an id that is no longer bound.
    public mutating func reset() { held = 0 }

    /// Translate a raw selector report into ordered press/release edges,
    /// advancing the latch. See the type doc for the full contract.
    public mutating func events(for selector: UInt8) -> [Edge] {
        if selector == held { return [] }              // duplicate / autorepeat
        var edges: [Edge] = []
        if held != 0 { edges.append(Edge(id: held, kind: .up)) }
        held = selector                                // advance unconditionally
        if selector != 0 { edges.append(Edge(id: selector, kind: .down)) }
        return edges
    }
}

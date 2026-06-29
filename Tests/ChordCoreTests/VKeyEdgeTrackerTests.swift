import Testing
import ChordCore  // the whole VKeyEdgeTracker contract is public — no @testable needed

/// Deterministic coverage for the vendor-HID v-key press/release edge math
/// (`Controller.handleVKey` was the wedge-bug site found by the vkey
/// adversarial review; the logic now lives in the pure `VKeyEdgeTracker`).
@Suite struct VKeyEdgeTrackerTests {
    private typealias Edge = VKeyEdgeTracker.Edge

    @Test func firstPressEmitsDownAndLatches() {
        var t = VKeyEdgeTracker()
        #expect(t.events(for: 0x1A) == [Edge(id: 0x1A, kind: .down)])
        #expect(t.held == 0x1A)
    }

    @Test func sameIdIsDedupedToNoEdges() {
        var t = VKeyEdgeTracker()
        _ = t.events(for: 0x1A)
        #expect(t.events(for: 0x1A) == [])  // duplicate report / autorepeat
        #expect(t.held == 0x1A)  // latch unchanged
    }

    @Test func zeroReleasesHeldKey() {
        var t = VKeyEdgeTracker()
        _ = t.events(for: 0x1A)
        #expect(t.events(for: 0) == [Edge(id: 0x1A, kind: .up)])
        #expect(t.held == 0)
    }

    @Test func rollAToBReleasesThenPresses() {
        var t = VKeyEdgeTracker()
        _ = t.events(for: 0x1A)
        // A fresh id before the 0: release A, then press B, in that order.
        #expect(t.events(for: 0x1B) == [Edge(id: 0x1A, kind: .up), Edge(id: 0x1B, kind: .down)])
        #expect(t.held == 0x1B)
        // The roll's `held = B` is what the next dedup compares against.
        #expect(t.events(for: 0x1B) == [])
    }

    /// After an A→B roll, the release `0` must emit `.up` of the *rolled-to* id
    /// (B), not the original A — i.e. the latch tracks provenance across the
    /// multi-step A→B→0 sequence.
    @Test func rollThenZeroReleasesRolledId() {
        var t = VKeyEdgeTracker()
        _ = t.events(for: 0x1A)
        _ = t.events(for: 0x1B)  // roll A→B; held is now B
        #expect(t.events(for: 0) == [Edge(id: 0x1B, kind: .up)])
        #expect(t.held == 0)
    }

    @Test func zeroWhileIdleIsNoOp() {
        var t = VKeyEdgeTracker()
        #expect(t.events(for: 0) == [])
        #expect(t.held == 0)
    }

    @Test func resetDropsLatchSoNoStaleUp() {
        var t = VKeyEdgeTracker()
        _ = t.events(for: 0x1A)
        t.reset()
        #expect(t.held == 0)
        #expect(t.events(for: 0) == [])  // release after reset emits nothing
    }

    /// Regression for the vkey-roadmap wedge: the latch advances on every
    /// call, decoupled from dispatch/pause. A release therefore always clears
    /// `held`, so the next press is clean (the bug latched a held id forever
    /// when a release arrived while paused). `VKeyEdgeTracker` has no pause
    /// input, so it cannot reintroduce that stick.
    @Test func latchAdvancesIndependentOfDispatch() {
        var t = VKeyEdgeTracker()
        _ = t.events(for: 0x26)  // press (caller may be paused)
        #expect(t.held == 0x26)
        #expect(t.events(for: 0) == [Edge(id: 0x26, kind: .up)])  // release
        #expect(t.held == 0)  // not stuck
        #expect(t.events(for: 0x27) == [Edge(id: 0x27, kind: .down)])  // next press clean
    }

    /// A full A→0→A cycle: press, release, re-press the same id all emit
    /// their edges (the dedup only suppresses a *repeat without an
    /// intervening release*).
    @Test func releaseThenSameIdPressesAgain() {
        var t = VKeyEdgeTracker()
        #expect(t.events(for: 0x1A) == [Edge(id: 0x1A, kind: .down)])
        #expect(t.events(for: 0) == [Edge(id: 0x1A, kind: .up)])
        #expect(t.events(for: 0x1A) == [Edge(id: 0x1A, kind: .down)])
        #expect(t.held == 0x1A)
    }
}

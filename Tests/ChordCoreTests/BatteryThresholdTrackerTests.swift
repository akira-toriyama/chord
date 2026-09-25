import Testing
import ChordCore  // the whole BatteryThresholdTracker contract is public — no @testable needed

/// The `[battery]` threshold / re-arm contract, isolated from HID
/// (`BatteryThresholdTracker` is what `Controller.handleBattery` consults).
@Suite struct BatteryThresholdTrackerTests {
    @Test func announcesOnceAtOrBelowThreshold() {
        var t = BatteryThresholdTracker(threshold: 10)
        #expect(t.observe(source: 0, level: 11) == false)
        #expect(t.observe(source: 0, level: 10) == true)
        #expect(t.observe(source: 0, level: 9) == false)  // latched: silent while draining
        #expect(t.observe(source: 0, level: 1) == false)
        #expect(t.latched == [0])
    }

    /// A half that is already low when the dongle first reports it (a
    /// fresh daemon start, a replug) announces on that first reading —
    /// no prior reading is needed.
    @Test func firstReadingAlreadyLowAnnounces() {
        var t = BatteryThresholdTracker(threshold: 10)
        #expect(t.observe(source: 1, level: 3) == true)
        #expect(t.latched == [1])
    }

    /// The central pushes `level = 0` on every peripheral disconnect (the
    /// dongle's own boot sequence included) — never a reading, and never
    /// a reason to re-arm.
    @Test func zeroIsNotAReading() {
        var t = BatteryThresholdTracker(threshold: 10)
        #expect(t.observe(source: 0, level: 0) == false)
        #expect(t.latched.isEmpty)
        #expect(t.observe(source: 0, level: 5) == true)
        #expect(t.observe(source: 0, level: 0) == false)
        #expect(t.latched == [0])
        #expect(t.observe(source: 0, level: 5) == false)  // reconnect at the same level: silent
    }

    @Test func aboveHundredIsIgnored() {
        var t = BatteryThresholdTracker(threshold: 100)
        #expect(t.observe(source: 0, level: 101) == false)
        #expect(t.observe(source: 0, level: 255) == false)
        #expect(t.latched.isEmpty)
    }

    @Test func rearmsOnlyAfterTheMargin() {
        var t = BatteryThresholdTracker(threshold: 10)
        #expect(t.rearmLevel == 15)
        #expect(t.observe(source: 0, level: 10) == true)
        #expect(t.observe(source: 0, level: 14) == false)  // under the re-arm level: still latched
        #expect(t.latched == [0])
        #expect(t.observe(source: 0, level: 8) == false)
        #expect(t.observe(source: 0, level: 15) == false)  // re-arming is silent
        #expect(t.latched.isEmpty)
        #expect(t.observe(source: 0, level: 10) == true)  // the next discharge announces again
    }

    @Test func sourcesAreIndependent() {
        var t = BatteryThresholdTracker(threshold: 20)
        #expect(t.observe(source: 0, level: 20) == true)
        #expect(t.observe(source: 1, level: 20) == true)
        #expect(t.observe(source: 1, level: 30) == false)  // re-arms source 1 only
        #expect(t.latched == [0])
        #expect(t.observe(source: 1, level: 19) == true)
        #expect(t.observe(source: 0, level: 19) == false)
    }

    /// A config save reloads the config; the latches must survive it
    /// unless the threshold itself moved.
    @Test func retunedKeepsLatchesUnlessThresholdMoves() {
        var t = BatteryThresholdTracker(threshold: 10)
        _ = t.observe(source: 0, level: 9)
        let same = t.retuned(to: 10)
        #expect(same.latched == [0])
        #expect(same.threshold == 10)
        let moved = t.retuned(to: 20)
        #expect(moved.latched.isEmpty)
        #expect(moved.threshold == 20)
        #expect(moved.rearmLevel == 25)
    }

    /// Nothing reads above 100, so a threshold within the margin of it
    /// announces once per config load and never re-arms.
    @Test func thresholdNearFullNeverRearms() {
        var t = BatteryThresholdTracker(threshold: 98)
        #expect(t.rearmLevel == 103)
        #expect(t.observe(source: 0, level: 98) == true)
        #expect(t.observe(source: 0, level: 100) == false)
        #expect(t.latched == [0])
    }
}

import Foundation

/// Pure threshold / re-arm math for the split peripheral battery report
/// (`[battery]`, chord 3.1.0+).
///
/// Readings are sparse and irregular: ZMK notifies a half's level only when
/// it changes, and a half stops sampling its fuel gauge after 30 s idle, so
/// a threshold crossing surfaces on the next change, not at a fixed cadence.
/// And a reading of `0` is not a level: the central pushes `level = 0` for a
/// half on every peripheral disconnect (ZMK `split/bluetooth/central.c`),
/// which the dongle forwards like any other report — its own boot produces
/// one per half before the first real value. Judged naively, every replug
/// would announce "0 %".
///
/// Contract (`level` in percent, `source` = the dongle's peripheral slot):
/// - `level == 0` or `level > 100`     → `false`, nothing changes
/// - not latched, `level <= threshold` → `true` (run the action), source latched
/// - not latched, `level > threshold`  → `false`
/// - latched, `level >= rearmLevel`    → `false`, source un-latched
/// - latched, otherwise                → `false`
///
/// One announcement per source per discharge: the latch holds until the
/// level climbs back by [rearmMargin], which is a charge, not the ±1 %
/// jitter around the threshold. A `threshold` above `100 - rearmMargin`
/// therefore never re-arms until the next config load — nothing can read
/// above 100. Lifted out of `Controller` so it is unit-testable and
/// HID-free; the Controller feeds it `(source, level)`, runs `action-shell`
/// when it says so, and carries it across config loads with [retuned(to:)]
/// — the file watcher reloads on every save, and a save is not a charge.
public struct BatteryThresholdTracker: Sendable {
    /// How far above `threshold` a level must climb before the same source
    /// can announce again.
    public static let rearmMargin = 5

    /// Percent; a reading at or below it announces.
    public let threshold: Int
    /// `threshold + rearmMargin`.
    public let rearmLevel: Int
    /// Sources that have announced and not yet re-armed.
    public private(set) var latched: Set<UInt8> = []

    public init(threshold: Int) {
        self.threshold = threshold
        self.rearmLevel = threshold + Self.rearmMargin
    }

    /// The tracker to keep across a config load: this one while the
    /// threshold is unchanged (the latches survive), a fresh one when it
    /// moved (the old latches were judged against a different line).
    public func retuned(to threshold: Int) -> BatteryThresholdTracker {
        threshold == self.threshold ? self : BatteryThresholdTracker(threshold: threshold)
    }

    /// Feed one report. `true` means this reading is the crossing for
    /// `source`: run the action, once.
    public mutating func observe(source: UInt8, level: UInt8) -> Bool {
        guard level != 0, level <= 100 else { return false }
        let percent = Int(level)
        if latched.contains(source) {
            if percent >= rearmLevel { latched.remove(source) }
            return false
        }
        guard percent <= threshold else { return false }
        latched.insert(source)
        return true
    }
}

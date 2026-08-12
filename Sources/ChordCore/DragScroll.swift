import Foundation

/// Drag-scroll: the one continuous-pointer mode chord has.
///
/// While the trigger of an `action-drag-scroll` binding is held, chord
/// pins the cursor and converts raw pointer motion into scroll events.
/// Everything in this file is pure arithmetic — the capture, the pin,
/// and the scroll post all live in an Adapter (see [MotionSource]).
///
/// This is deliberately NOT a gesture: no path, no shape, no history is
/// examined. Each delta is folded into the next scroll tick and thrown
/// away. Path-based input remains a non-goal (docs/non-goals.md §7).

/// Which pointer axes a drag-scroll binding converts to scroll.
public enum DragScrollAxis: String, CaseIterable, Hashable, Sendable, Codable {
    /// Both axes (default).
    case both
    /// Vertical only — horizontal pointer motion is discarded.
    case vertical
    /// Horizontal only — vertical pointer motion is discarded.
    case horizontal
}

/// The tuning an `action-drag-scroll` binding carries. Lives inside
/// [Action.dragScroll] rather than on [Binding] so the action can never
/// exist half-configured (contrast `actionKeysDelayMs`, which modifies a
/// keystroke LIST and therefore belongs to the binding).
public struct DragScrollSpec: Hashable, Sendable {
    public static let defaultSpeed = 1.0
    /// Hard watchdog ceiling, in ms. Bounds the worst failure mode: if the
    /// release edge is never delivered (a dropped v-key release report, a
    /// dongle unplugged mid-drag), the mode would otherwise pin the cursor
    /// and eat pointer motion forever. See `Controller.startDragScroll`.
    public static let defaultMaxMs = 30_000

    /// Multiplier applied to the raw pointer delta before it becomes
    /// scroll pixels. `1.0` = one scroll pixel per pointer pixel.
    public var speed: Double
    public var axis: DragScrollAxis
    /// Flip the mapping. Default (`false`) posts a scroll whose sign
    /// matches the pointer delta; `true` negates both axes.
    public var invert: Bool
    /// Auto-stop after this many ms, whatever happens to the release edge.
    public var maxMs: Int

    public init(
        speed: Double = DragScrollSpec.defaultSpeed,
        axis: DragScrollAxis = .both,
        invert: Bool = false,
        maxMs: Int = DragScrollSpec.defaultMaxMs
    ) {
        self.speed = speed
        self.axis = axis
        self.invert = invert
        self.maxMs = maxMs
    }
}

/// One relative pointer movement, as the Adapter reads it off the OS.
/// Screen convention: `+dx` = right, `+dy` = down.
public struct MotionDelta: Hashable, Sendable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// One scroll event's worth of whole pixels, ready to post.
public struct ScrollTick: Hashable, Sendable {
    public var vertical: Int32
    public var horizontal: Int32
    public init(vertical: Int32, horizontal: Int32) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

/// Folds raw pointer deltas into whole-pixel scroll ticks.
///
/// Carries the sub-pixel residual across events, which is what makes
/// `speed < 1.0` usable: truncating each delta independently would
/// discard every movement smaller than `1 / speed` pixels, so a slow
/// drag would not scroll at all.
public struct DragScrollAccumulator: Sendable {
    public let spec: DragScrollSpec
    private var residualX: Double = 0
    private var residualY: Double = 0

    public init(spec: DragScrollSpec) {
        self.spec = spec
    }

    /// Drop the sub-pixel carry (mode start / stop).
    public mutating func reset() {
        residualX = 0
        residualY = 0
    }

    /// Fold one pointer delta in. Returns the scroll to post, or `nil`
    /// while the accumulated motion is still sub-pixel on both axes.
    public mutating func step(_ d: MotionDelta) -> ScrollTick? {
        guard d.dx.isFinite, d.dy.isFinite else { return nil }
        // Axis filter BEFORE the residual: a vertical-only binding must
        // drop horizontal wobble outright, not bank it for later.
        let rawX = spec.axis == .vertical ? 0 : d.dx
        let rawY = spec.axis == .horizontal ? 0 : d.dy
        // Sign convention: the posted scroll carries the SAME sign as the
        // pointer delta (measured end-to-end — a +997px pointer move right
        // posts exactly h=+997, and likewise for the other three
        // directions). Which way that *reads* on screen is the app's and
        // the user's scroll-direction preference to decide; `invert` flips
        // both axes together for anyone who wants the opposite.
        let gain = spec.speed * (spec.invert ? -1 : 1)
        residualX += rawX * gain
        residualY += rawY * gain
        guard residualX.isFinite, residualY.isFinite else {
            reset()
            return nil
        }
        let takeX = residualX.rounded(.towardZero)
        let takeY = residualY.rounded(.towardZero)
        guard takeX != 0 || takeY != 0 else { return nil }
        residualX -= takeX
        residualY -= takeY
        return ScrollTick(
            vertical: DragScrollAccumulator.clamp(takeY),
            horizontal: DragScrollAccumulator.clamp(takeX))
    }

    /// Saturating Double → Int32. A pointer delta that large is not
    /// physically reachable, but `Int32(_:)` traps rather than wrapping,
    /// and a trap in the tap callback takes the daemon down.
    static func clamp(_ v: Double) -> Int32 {
        guard v.isFinite else { return 0 }
        if v >= Double(Int32.max) { return .max }
        if v <= Double(Int32.min) { return .min }
        return Int32(v)
    }
}

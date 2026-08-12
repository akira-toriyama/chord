import ChordCore
import Foundation

/// Synthetic [MotionSource] for end-to-end drag-scroll tests without a
/// real pointer. Tests drive deltas through [feed] and assert on
/// [captureLog] — the arm / disarm history, which is what the wedge
/// safety nets are actually about.
///
/// [feed] mirrors the real adapter: a delta is only delivered while
/// capturing is armed, so a test that forgets to open the mode sees the
/// same nothing the production tap would deliver.
public final class TestMotionSource: MotionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (MotionDelta) -> Void)?
    private var capturing = false
    /// Every `setCapturing` transition, in order. `[true, false]` is one
    /// complete drag.
    public private(set) var captureLog: [Bool] = []
    /// Every `setCapturing` CALL, transition or not. Distinct from
    /// [captureLog] on purpose: re-arming an already-armed capture is a
    /// no-op transition, so only this records whether the Controller's
    /// per-trigger idempotence actually held (an autorepeat that re-latched
    /// the anchor would show up here and nowhere else).
    public private(set) var setCapturingCalls: [Bool] = []
    /// Deltas that were actually delivered (i.e. arrived while armed).
    public private(set) var delivered: [MotionDelta] = []
    /// How many times the capture was installed. The real adapter installs
    /// at most once (`if tap != nil { return }`), and the install is gated
    /// on the config declaring a drag-scroll binding — so a keyboard-only
    /// config must leave this at 0.
    public private(set) var startCount = 0

    public init() {}

    @MainActor
    public func start(
        handler: @escaping @Sendable (MotionDelta) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        // Mirrors MacOSMotionSource: a second start is a no-op, so a reload
        // does not double-install.
        guard self.handler == nil else { return }
        self.handler = handler
        startCount += 1
    }

    @MainActor
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        self.handler = nil
        if capturing {
            capturing = false
            captureLog.append(false)
        }
    }

    public nonisolated func setCapturing(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        setCapturingCalls.append(on)
        guard capturing != on else { return }
        capturing = on
        captureLog.append(on)
    }

    /// True while a drag-scroll mode holds the pointer.
    public var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return capturing
    }

    /// Drive one pointer delta through the handler. Ignored (and not
    /// recorded) when disarmed, exactly as the real tap is.
    public func feed(_ delta: MotionDelta) {
        lock.lock()
        let h = capturing ? handler : nil
        if h != nil { delivered.append(delta) }
        lock.unlock()
        h?(delta)
    }
}

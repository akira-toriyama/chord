import AppKit
import ChordCore
import CoreGraphics
import Foundation

/// CGEventTap-backed [MotionSource] — relative pointer motion for
/// `action-drag-scroll`, plus the cursor pin that makes the mode a
/// scroll rather than a drag.
///
/// **Why a second tap.** Motion is high-rate (~96 events/s on this
/// hardware) and a tap in the mask means the WindowServer round-trips
/// every one of them through chord before delivering it. The main tap's
/// mask therefore stays keyboard + discrete-mouse, and this one is
/// * created only when the config declares an `action-drag-scroll`
///   binding (`Controller.maybeStartMotionSource`), and
/// * `tapEnable`d only for the span the trigger is actually held.
/// A config without drag-scroll never creates it; a config with one
/// pays nothing between drags. Same least-privilege shape as the
/// conditional [VKeyHIDSource] install.
///
/// **The pin.** Consuming motion events does NOT stop the cursor — the
/// WindowServer moves the pointer from the HID stream, upstream of the
/// session tap. The cursor is held still by warping it back to the
/// anchor on every event. `CGWarpMouseCursorPosition` generates no
/// tap-visible event of its own (measured: 100 warps with the mouse
/// physically still produced 0 `mouseMoved`), so warping cannot feed
/// itself, and the deltas we read stay the true hardware deltas.
///
/// Warping, rather than `CGAssociateMouseAndMouseCursorPosition(false)`,
/// is deliberate: disassociation is process-external global state, so a
/// crash mid-drag would leave the user's pointer dead until logout. A
/// crash mid-warp just stops warping.
///
/// Threading: identical to [MacOSEventSource] — `start` / `stop` are
/// `@MainActor` and the tap is scheduled on the main run loop, so the
/// callback fires on the main thread and must return synchronously.
/// `setCapturing` is the exception: the watchdog timer calls it from its
/// own queue, so it hops to main when it isn't already there.
public final class MacOSMotionSource: MotionSource, @unchecked Sendable {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@Sendable (MotionDelta) -> Void)?

    /// Where the cursor is pinned for the current drag. Written on arm,
    /// read on every motion event. Main thread only.
    private var anchor: CGPoint?
    /// Whether delivery is armed. Distinguishes "we disabled the tap" from
    /// "the system disabled the tap", so the watchdog re-enable in the
    /// callback doesn't resurrect a mode we deliberately ended.
    private var capturing = false

    public init() {}

    @MainActor
    public func start(
        handler: @escaping @Sendable (MotionDelta) -> Void
    ) throws {
        if tap != nil {
            Log.line("motion-tap: already installed")
            return
        }
        self.handler = handler

        // `mouseMoved` covers the no-button case. The `*Dragged` variants
        // are what the OS sends instead once a mouse button is down —
        // which is the normal state when the drag-scroll trigger IS a
        // mouse button (`input = "side1"`).
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }

        let info = Unmanaged.passUnretained(self).toOpaque()
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: MacOSMotionSource.tapCallback,
                userInfo: info
            )
        else {
            Log.line("motion-tap: tapCreate failed — Accessibility not granted?")
            throw EventTapError.tapCreateFailed
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        // Installed DISARMED: nothing is delivered until a drag-scroll
        // binding fires. This is the whole point of the separate tap.
        CGEvent.tapEnable(tap: port, enable: false)
        self.tap = port
        self.runLoopSource = src
        Log.line("motion-tap: installed, disarmed (mask=0x\(String(mask, radix: 16)))")
    }

    @MainActor
    public func stop() {
        applyCapturing(false)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        handler = nil
        Log.line("motion-tap: stopped")
    }

    public nonisolated func setCapturing(_ on: Bool) {
        // The common caller is the tap callback, which already runs on the
        // main thread — do it inline there so arming takes effect before
        // the consume decision returns. The watchdog fires on its own
        // queue, where the hop is both necessary and free (it is rare).
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyCapturing(on) }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyCapturing(on) }
            }
        }
    }

    @MainActor
    private func applyCapturing(_ on: Bool) {
        guard let port = tap, capturing != on else { return }
        capturing = on
        if on {
            // Latch where the cursor is now; every motion event warps back
            // here until the mode ends.
            anchor = CGEvent(source: nil)?.location
            CGEvent.tapEnable(tap: port, enable: true)
            Log.debug("motion-tap: armed (anchor=\(anchor.map(String.init(describing:)) ?? "?"))")
        } else {
            CGEvent.tapEnable(tap: port, enable: false)
            anchor = nil
            // Debug, like its `armed` counterpart: the user-visible event
            // is the Controller's `drag-scroll: stop` line one layer up,
            // and this fires on every drag.
            Log.debug("motion-tap: disarmed")
        }
    }

    private static let tapCallback: CGEventTapCallBack = {
        _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<MacOSMotionSource>
            .fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Only resurrect a tap the system disabled under us. Our own
            // `tapEnable(false)` can surface here too, and re-enabling
            // that would restart a mode the user just ended.
            if me.capturing, let port = me.tap {
                CGEvent.tapEnable(tap: port, enable: true)
                Log.line("motion-tap: re-enabled after \(type.rawValue)")
            }
            return Unmanaged.passUnretained(event)
        }

        // Armed ⇒ the pointer belongs to chord for this span: pin it, read
        // the delta, and swallow the event so nothing downstream sees a
        // pointer that (visually) never moved.
        guard me.capturing, let handler = me.handler else {
            return Unmanaged.passUnretained(event)
        }
        if let anchor = me.anchor {
            CGWarpMouseCursorPosition(anchor)
        }
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)
        // No per-event Log.debug here on purpose: this fires ~96×/s while
        // armed, which is the one place the gated-logging cost is real.
        handler(MotionDelta(dx: Double(dx), dy: Double(dy)))
        return nil
    }
}

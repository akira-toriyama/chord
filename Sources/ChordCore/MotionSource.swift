import Foundation

/// The seam between Core and a **relative-pointer-motion** adapter.
///
/// Separate from [EventSource] on purpose. `EventSource` carries the
/// discrete events every binding matches on, and its handler returns a
/// consume / pass decision. Motion has neither property: it is
/// continuous, it never reaches the Matcher, and while a drag-scroll
/// mode is armed every motion event is consumed unconditionally (the
/// cursor is pinned — letting the OS also see the movement is exactly
/// what we are suppressing). One protocol carrying both shapes would
/// have to make half its contract meaningless in each direction.
///
/// Lifecycle: `start` installs the capture **disarmed**. Nothing is
/// delivered, and the OS pays nothing, until `setCapturing(true)`.
/// That is the whole reason this is a second source rather than extra
/// bits in `EventSource`'s mask — a config with no `action-drag-scroll`
/// binding never installs it at all, and one that has such a binding
/// only pays while the trigger is actually held.
public protocol MotionSource: AnyObject, Sendable {
    /// Install the capture, disarmed. `handler` is invoked synchronously
    /// per motion event while armed, on the same run loop as the event
    /// tap, so it must return quickly.
    @MainActor
    func start(handler: @escaping @Sendable (MotionDelta) -> Void) throws

    /// Arm (`true`) / disarm (`false`) delivery. Arming latches the
    /// cursor anchor the adapter pins to; disarming releases it.
    ///
    /// Idempotent, and callable from the tap callback (the drag-scroll
    /// mode starts and stops from inside a consume decision) as well as
    /// from the watchdog timer's queue.
    nonisolated
        func setCapturing(_ on: Bool)

    /// Tear the capture down. Idempotent; implies `setCapturing(false)`.
    @MainActor
    func stop()
}

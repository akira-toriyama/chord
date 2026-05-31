import Foundation

/// The seam between Core and an event-producing adapter.
///
/// Real chord uses [ChordAdapterMacOS.MacOSEventSource] (CGEventTap)
/// — its callback fires on the tap's run loop and **must return
/// synchronously** with the consume/pass decision. AsyncStream is
/// the wrong shape for that path, so the protocol takes a closure
/// invoked inline from the tap callback. Adding a new event source
/// (a different tap, a test stub) means a new `EventSource`
/// conformer in an Adapter module — never a `#if` in Core.
public protocol EventSource: AnyObject, Sendable {
    /// Install the tap. `handler` is invoked synchronously per
    /// input event; the return value decides whether the event is
    /// passed through to the OS or swallowed. The handler runs on
    /// the same run loop as the tap, so it must be quick — long
    /// work (shell exec etc.) belongs in an async task spawned
    /// from inside.
    @MainActor
    func start(handler: @escaping @Sendable (InputEvent) -> EventOutcome) throws

    /// Tear the tap down. Idempotent.
    @MainActor
    func stop()
}

/// What [EventSource]'s handler emits.
public enum EventOutcome: Sendable {
    /// Let the OS continue processing the event.
    case passthrough
    /// Swallow the event — no further app or system sees it.
    case consume
}

/// Up/down indicator on an [InputEvent]. v2 added `.up` so bindings
/// can react to releases (`action-shell-on-up`) and so the OS never
/// sees a "phantom" up for a key whose down chord consumed at the
/// tap. Scroll events are always `.down` — the wheel has no
/// release semantics.
///
/// `.modifiersChanged` is the bare-modifier transition (cmd lifted,
/// shift pressed, …). It never matches a binding's trigger; the
/// Controller routes it to the hold-while auto-clear path instead
/// of the matcher. `trigger` is a placeholder on these events.
public enum EventKind: Sendable, Hashable {
    case down
    case up
    case modifiersChanged
}

/// What an EventSource hands to the consumer.
public struct InputEvent: Sendable, Hashable {
    public var trigger: Trigger
    public var modifiers: Modifiers
    /// Frontmost app at the time of the event (for app-scoped
    /// bindings). The matcher reads this directly.
    public var frontmostBundleID: String?
    /// Whether this is a press (`.down`) or release (`.up`). v1
    /// EventSources only emitted `.down` — the field defaults to it
    /// so call sites that don't care compile unchanged.
    public var kind: EventKind
    /// True for events the adapter itself synthesised (e.g. an
    /// `action-keys` post). The tap tags these so the callback
    /// short-circuits before they re-enter the matcher.
    public var isSynthetic: Bool
    /// chord 0.9.0+: macOS sends additional `keyDown` events while a
    /// key is physically held (typematic autorepeat). `isRepeat == true`
    /// flags these so the Controller can apply per-binding
    /// `repeat = "fire-each" | "ignore" | "passthrough"` strategy.
    /// Only meaningful on `.down`; always false on `.up` /
    /// `.modifiersChanged`.
    public var isRepeat: Bool

    public init(trigger: Trigger, modifiers: Modifiers,
                frontmostBundleID: String?,
                kind: EventKind = .down,
                isSynthetic: Bool = false,
                isRepeat: Bool = false) {
        self.trigger = trigger
        self.modifiers = modifiers
        self.frontmostBundleID = frontmostBundleID
        self.kind = kind
        self.isSynthetic = isSynthetic
        self.isRepeat = isRepeat
    }
}

import ChordCore
import Foundation

/// Synthetic EventSource for end-to-end tests of the matcher
/// pipeline without real HID hardware. Tests inject `InputEvent`
/// via [feed] and observe what the handler did via the recorded
/// `outcomes`.
public final class TestEventSource: EventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (InputEvent) -> EventOutcome)?
    public private(set) var outcomes: [(InputEvent, EventOutcome)] = []

    public init() {}

    @MainActor
    public func start(
        handler: @escaping @Sendable (InputEvent) -> EventOutcome
    ) throws {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    @MainActor
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        self.handler = nil
    }

    /// Drive an event through the handler. Returns the handler's
    /// outcome so callers can assert.
    @discardableResult
    public func feed(_ event: InputEvent) -> EventOutcome {
        lock.lock()
        let h = handler
        lock.unlock()
        let outcome = h?(event) ?? .passthrough
        lock.lock()
        outcomes.append((event, outcome))
        lock.unlock()
        return outcome
    }
}

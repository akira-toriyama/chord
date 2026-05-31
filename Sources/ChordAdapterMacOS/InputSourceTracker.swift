import Carbon
import Foundation

/// chord 0.9.0+: tracks the macOS current keyboard input source ID
/// (e.g. `com.apple.keylayout.US`, `com.apple.inputmethod.Kotoeri.…`)
/// so the event-tap callback can match `input-source = "…"` filters
/// without re-querying Carbon TIS on every event.
///
/// Mirrors [FrontmostTracker]'s shape:
///   * `start()` seeds the value and subscribes to
///     `kTISNotifySelectedKeyboardInputSourceChanged` on the
///     `DistributedNotificationCenter` (TIS posts there, not on the
///     in-process NSWorkspace center)
///   * the cached value is read lock-free from the hot path
public final class InputSourceTracker: @unchecked Sendable {
    public static let shared = InputSourceTracker()

    private let lock = NSLock()
    private var current: String?

    public var id: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func start() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(
                kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Re-read the current source. Called once at start and on every
    /// TIS-posted change. Cheap (one CoreFoundation call) so polling
    /// fallback isn't necessary; the observer covers every transition.
    private func refresh() {
        guard let src = TISCopyCurrentKeyboardInputSource()?
                .takeRetainedValue()
        else { return }
        guard let ptr = TISGetInputSourceProperty(
                src, kTISPropertyInputSourceID)
        else { return }
        let cf = Unmanaged<CFString>.fromOpaque(ptr)
            .takeUnretainedValue()
        let id = cf as String
        lock.lock(); defer { lock.unlock() }
        current = id
    }
}

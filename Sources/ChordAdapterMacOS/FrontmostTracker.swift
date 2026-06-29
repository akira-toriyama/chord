import AppKit
import Foundation

/// Tracks the frontmost app bundle id so the event-tap callback can
/// match app-scoped bindings without doing the
/// `NSWorkspace.shared.frontmostApplication` query from inside the
/// hot path (it's a `@MainActor` call and the tap fires on a
/// dedicated run loop thread).
public final class FrontmostTracker: @unchecked Sendable {
    public static let shared = FrontmostTracker()

    private let lock = NSLock()
    private var current: String?

    public var bundleID: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    @MainActor
    public func start() {
        update(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app =
                note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.update(app?.bundleIdentifier)
        }
    }

    private func update(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        current = id
    }
}

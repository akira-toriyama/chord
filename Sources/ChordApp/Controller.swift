import AppKit
import ChordAdapterMacOS
import ChordCore
import Foundation

/// Orchestrates the daemon. Owns the EventSource, the latest
/// Matcher snapshot, and the IPC listeners.
@MainActor
public final class Controller {
    private let source: any EventSource
    private var matcher: Matcher
    private var config: ChordConfig
    private var observers: [NSObjectProtocol] = []
    private var configWatcher: DispatchSourceFileSystemObject?

    public init(source: any EventSource = MacOSEventSource()) {
        self.source = source
        self.config = .init()
        self.matcher = Matcher(bindings: [], excludeApps: [])
    }

    public func start() throws {
        loadConfig(reason: "startup")
        FrontmostTracker.shared.start()

        // Strong, Sendable capture for the synchronous tap handler.
        let weakSelf = WeakWrap(self)
        try source.start { event in
            guard let me = weakSelf.value else { return .passthrough }
            return me.handle(event)
        }

        installControlIPC()
        installConfigWatcher()
        Control.writeStatus("started bindings=\(matcher.bindings.count)")
    }

    public func stop() {
        source.stop()
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
        }
        observers.removeAll()
        configWatcher?.cancel()
        configWatcher = nil
        Control.writeStatus("stopped")
    }

    // MARK: - hot path

    nonisolated private func handle(_ event: InputEvent) -> EventOutcome {
        // The tap callback fires on its own run loop thread. We
        // snapshot `matcher` once (assignment is atomic enough at
        // value-type granularity in Swift) and act without
        // bouncing to main — main bounces would deadlock the tap.
        let snapshot = matcherSnapshot()
        let me = Matcher.Event(trigger: event.trigger,
                               modifiers: event.modifiers,
                               bundleID: event.frontmostBundleID)
        guard let binding = snapshot.find(me) else { return .passthrough }
        ActionDispatcher.dispatch(binding)
        Control.writeStatus("fired \(binding.name)")
        return .consume
    }

    nonisolated private func matcherSnapshot() -> Matcher {
        matcherLock.lock()
        defer { matcherLock.unlock() }
        return sharedMatcher ?? Matcher(bindings: [], excludeApps: [])
    }

    private func publishMatcher() {
        matcherLock.lock()
        sharedMatcher = matcher
        matcherLock.unlock()
    }

    // MARK: - config

    public func reload() {
        loadConfig(reason: "reload")
        Control.writeStatus("reloaded bindings=\(matcher.bindings.count)")
    }

    private func loadConfig(reason: String) {
        do {
            let result = try Config.load()
            for w in result.warnings { Log.line("config: \(w)") }
            self.config = result.config
            self.matcher = Matcher(
                bindings: result.config.bindings,
                excludeApps: result.config.options.excludeApps)
            publishMatcher()
            Log.line("config \(reason): \(matcher.bindings.count) bindings " +
                     "loaded, \(result.droppedBindings) dropped")
        } catch {
            Log.line("config \(reason) error: \(error)")
        }
    }

    private func installControlIPC() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name(Control.reload),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        })
        observers.append(center.addObserver(
            forName: Notification.Name(Control.quit),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                NSApp?.terminate(nil)
                exit(0)
            }
        })
    }

    private func installConfigWatcher() {
        let path = ChordConfig.path
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete],
            queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.reload() }
            // Atomic-save (vim, most editors) replaces the inode;
            // close + re-arm so we keep tracking after a rename.
            src.cancel()
            self?.installConfigWatcher()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        self.configWatcher = src
    }
}

/// Sendable weak reference to a non-Sendable class. Lets the
/// CGEventTap callback (synchronous, on the tap thread) call back
/// into the Controller without `@MainActor`-isolating the closure.
private final class WeakWrap: @unchecked Sendable {
    weak var value: Controller?
    init(_ v: Controller) { self.value = v }
}

// File-private cross-thread state: the tap callback thread reads
// the latest published Matcher snapshot; the @MainActor controller
// writes it after a config reload. Hoisted out of the @MainActor
// class so the static-property isolation rules don't apply.
nonisolated(unsafe) private var sharedMatcher: Matcher?
private let matcherLock = NSLock()

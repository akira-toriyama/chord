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
        if isPaused() { return .passthrough }
        let snapshot = matcherSnapshot()
        let me = Matcher.Event(trigger: event.trigger,
                               modifiers: event.modifiers,
                               bundleID: event.frontmostBundleID)
        guard let binding = snapshot.find(me) else { return .passthrough }
        ActionDispatcher.dispatch(binding)
        Control.writeStatus("fired \(binding.name)")
        return .consume
    }

    nonisolated private func isPaused() -> Bool {
        pauseLock.lock(); defer { pauseLock.unlock() }
        return pausedFlag
    }

    private func setPaused(_ value: Bool) {
        pauseLock.lock()
        pausedFlag = value
        pauseLock.unlock()
        let status = value ? "paused" : "resumed"
        Log.line("control: \(status)")
        Control.writeStatus("\(status) bindings=\(matcher.bindings.count)")
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
                fallbacks: result.config.fallbacks,
                excludeApps: result.config.options.excludeApps)
            publishMatcher()
            Log.line("config \(reason): \(matcher.bindings.count) bindings, " +
                     "\(matcher.fallbacks.count) fallbacks, " +
                     "\(result.droppedBindings) dropped")
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
        observers.append(center.addObserver(
            forName: Notification.Name(Control.pause),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setPaused(true) }
        })
        observers.append(center.addObserver(
            forName: Notification.Name(Control.resume),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setPaused(false) }
        })
    }

    private func installConfigWatcher() {
        let path = ChordConfig.path

        if let src = makeFileWatcher(path: path) {
            self.configWatcher = src
            return
        }

        // File doesn't exist yet — watch the parent directory so we
        // can attach the file watcher the moment the user creates
        // it (e.g. first `cp config.toml ~/.config/chord/`). Without
        // this, a daemon launched before the config exists would
        // never auto-reload.
        let dir = (path as NSString).deletingLastPathComponent
        // Make the directory itself so the parent open succeeds for
        // a brand-new install. Ignore errors — if it really can't
        // be created the daemon still runs (just without auto-reload).
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let dirFD = open(dir, O_EVTONLY)
        guard dirFD != -1 else {
            Log.line("config: cannot watch \(dir) — auto-reload disabled")
            return
        }
        let dirSrc = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write, .rename],
            queue: .main)
        dirSrc.setEventHandler { [weak self] in
            // A file landed in the directory. If it's our config,
            // swap to the file-level watcher.
            if FileManager.default.fileExists(atPath: path) {
                dirSrc.cancel()
                Task { @MainActor in
                    self?.reload()
                    self?.installConfigWatcher()
                }
            }
        }
        dirSrc.setCancelHandler { close(dirFD) }
        dirSrc.resume()
        self.configWatcher = dirSrc
    }

    private func makeFileWatcher(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return nil }
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
        return src
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

// Same shape for the paused flag — the tap callback reads it once
// per event, the @MainActor controller flips it on
// `chord --pause` / `--resume`.
nonisolated(unsafe) private var pausedFlag: Bool = false
private let pauseLock = NSLock()

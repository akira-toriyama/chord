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

        // Branch on event kind before consulting the matcher. The
        // matcher only deals with `.down` events; `.up` flows
        // through the pending-up table for paired consume + onUp
        // dispatch; `.modifiersChanged` flows through the hold-while
        // cleanup path and never reaches the matcher.
        switch event.kind {
        case .modifiersChanged:
            clearStaleVariables(currentMods: event.modifiers)
            return .passthrough
        case .up:
            return handleKeyUp(trigger: event.trigger)
        case .down:
            break
        }

        let snapshot = matcherSnapshot()
        let state = stateSnapshot()
        let me = Matcher.Event(trigger: event.trigger,
                               modifiers: event.modifiers,
                               bundleID: event.frontmostBundleID,
                               state: state)
        guard let binding = snapshot.find(me) else { return .passthrough }
        // Intercept setVariable: state ownership lives here, not in
        // the dispatcher (which is in the Adapter layer and has no
        // legitimate reason to know about the controller's store).
        if case .setVariable(let name, let value) = binding.action {
            applyVariable(name: name, value: value,
                          holdWhile: binding.holdWhile)
            Log.debug("state: set \(name)=\(value) " +
                      "via '\(binding.name)'" +
                      (binding.holdWhile.map {
                          " (hold-while=0x\(String($0.rawValue, radix: 16)))"
                      } ?? ""))
        } else {
            ActionDispatcher.dispatch(binding)
        }
        // Register pairing: B1 contract — the OS never saw this
        // down, so the corresponding up must also be consumed.
        // The binding (with its onUpAction) is what handleKeyUp
        // dispatches against.
        registerPendingUp(trigger: event.trigger, binding: binding)
        Control.writeStatus("fired \(binding.name)")
        return .consume
    }

    /// Key/mouse `.up` arrived. If we consumed the paired down, we
    /// must also consume this up so the OS sees a coherent
    /// up/down pair (it saw neither half). Fires the binding's
    /// `onUpAction` if present.
    nonisolated private func handleKeyUp(trigger: Trigger) -> EventOutcome {
        guard let binding = takePendingUp(trigger: trigger) else {
            return .passthrough
        }
        if let onUp = binding.onUpAction {
            if case .setVariable(let name, let value) = onUp {
                applyVariable(name: name, value: value,
                              holdWhile: binding.holdWhile)
                Log.debug("state: set \(name)=\(value) " +
                          "via '\(binding.name)' (on-up)")
            } else {
                // Dispatch the on-up action under the original
                // binding's name (for logging / status output). The
                // dispatcher only looks at `.action`, so a swap is
                // enough — no need to mutate the binding store.
                var upBinding = binding
                upBinding.action = onUp
                ActionDispatcher.dispatch(upBinding)
            }
        }
        return .consume
    }

    /// Snapshot of the variable store, value-typed and lock-free
    /// to read on the tap thread (the dictionary is copied inside the
    /// lock then released). The matcher consumes this via
    /// [Matcher.Event.state].
    nonisolated private func stateSnapshot() -> StateSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        var out: [String: Int] = [:]
        for (k, e) in (sharedState ?? [:]) { out[k] = e.value }
        return StateSnapshot(variables: out)
    }

    /// Apply a [Action.setVariable] under [stateLock]. Writing 0
    /// clears the entry (matches the matcher's "unset == 0" reading,
    /// keeps the dict from accumulating zeroed keys over time).
    nonisolated private func applyVariable(name: String, value: Int,
                                           holdWhile: Modifiers?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if sharedState == nil { sharedState = [:] }
        if value == 0 {
            sharedState?.removeValue(forKey: name)
        } else {
            sharedState?[name] = VariableEntry(value: value,
                                               holdWhile: holdWhile)
        }
    }

    /// Wipe the variable store. Called on every config reload — the
    /// new config may have dropped a binding that owned a variable,
    /// leaving us with state that nothing can ever clear. Clean slate
    /// on reload sidesteps the leak (and matches the user's mental
    /// model: "reload restarts the daemon's state").
    nonisolated private func resetState() {
        stateLock.lock()
        sharedState = nil
        stateLock.unlock()
        pendingUpsLock.lock()
        pendingUps = nil
        pendingUpsLock.unlock()
    }

    /// Walk the variable store and remove any entry whose `holdWhile`
    /// mask is no longer satisfied by the current modifier mask.
    /// Called from the `.modifiersChanged` path; touches the lock
    /// once per flagsChanged event (cheap — the dict is tiny).
    nonisolated private func clearStaleVariables(currentMods: Modifiers) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var dict = sharedState else { return }
        var mutated = false
        for (name, entry) in dict {
            guard let hold = entry.holdWhile else { continue }
            if !hold.isStillHeld(in: currentMods) {
                dict.removeValue(forKey: name)
                mutated = true
                Log.debug("state: clear \(name) (hold-while released)")
            }
        }
        if mutated { sharedState = dict }
    }

    /// Record a binding so its `.up` half can implicitly consume the
    /// release event and dispatch any `onUpAction`. Keyed by Trigger
    /// alone — modifiers may transition between the down and up
    /// (the user lifts cmd before lifting the primary key).
    nonisolated private func registerPendingUp(trigger: Trigger,
                                               binding: Binding) {
        // Skip pairing for triggers that have no up half (scroll).
        if case .scroll = trigger { return }
        pendingUpsLock.lock()
        defer { pendingUpsLock.unlock() }
        if pendingUps == nil { pendingUps = [:] }
        pendingUps?[trigger] = binding
    }

    nonisolated private func takePendingUp(trigger: Trigger) -> Binding? {
        pendingUpsLock.lock()
        defer { pendingUpsLock.unlock() }
        return pendingUps?.removeValue(forKey: trigger)
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
            for w in result.warnings { Log.line("config: \(w.message)") }
            self.config = result.config
            self.matcher = Matcher(
                bindings: result.config.bindings,
                fallbacks: result.config.fallbacks,
                excludeApps: result.config.options.excludeApps)
            publishMatcher()
            // Reload wipes the variable store — the new config may
            // have removed the binding that owned a variable, and a
            // stale entry no one can clear would silently keep a
            // condition-gated binding alive.
            resetState()
            let undef = result.warnings.lazy
                .filter { $0.kind == .undefinedAlias }
                .count
            let hint = (result.droppedBindings > 0 || result.warnings.count > 0)
                ? " (run --validate --strict for details)" : ""
            Log.line("config \(reason): \(matcher.bindings.count) bindings, " +
                     "\(matcher.fallbacks.count) fallbacks, " +
                     "\(result.config.aliases.count) aliases, " +
                     "undefined-aliases=\(undef), " +
                     "dropped=\(result.droppedBindings)\(hint)")
            // Snapshot the loaded state for `chord --reload --dry-run`
            // to diff against on the next edit. Failures here are
            // non-fatal — the daemon keeps running, dry-run just
            // shows everything as "added" until the next reload.
            saveLoadedSnapshot(result: result)
        } catch {
            Log.line("config \(reason) error: \(error)")
        }
    }

    private func saveLoadedSnapshot(result: Config.ParseResult) {
        let doc = BindingsSchema.makeDocument(from: result)
        do {
            let data = try BindingsSchema.encodeJSON(doc)
            try data.write(to: URL(fileURLWithPath:
                BindingsSchema.snapshotPath))
        } catch {
            Log.line("snapshot: write failed — \(error)")
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

// v2 state store. Both writes (Action.setVariable interception) and
// reads (per-event snapshot) happen on the tap thread, so the lock
// window is the dict copy itself — never wraps a callback. The
// `holdWhile` field records which modifier mask, if any, ties the
// variable's lifetime to a held-down mod set; flagsChanged handling
// inspects this to auto-clear on release.
struct VariableEntry: Sendable {
    let value: Int
    let holdWhile: Modifiers?
}
nonisolated(unsafe) var sharedState: [String: VariableEntry]?
let stateLock = NSLock()

// Pending-up table: tap-side bookkeeping for the B1 contract
// (consume the up of every consumed down so the OS sees a coherent
// down/up pair, where it actually saw neither). Keyed by Trigger
// alone — the modifier mask may have changed by the time the
// release arrives (user lifts cmd before lifting the primary key).
nonisolated(unsafe) var pendingUps: [Trigger: Binding]?
let pendingUpsLock = NSLock()

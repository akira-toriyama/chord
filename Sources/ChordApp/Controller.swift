import AppKit
import ChordAdapterMacOS
import ChordCore
import Foundation

/// Orchestrates the daemon. Owns the EventSource, the latest
/// Matcher snapshot, and the IPC listeners.
@MainActor
public final class Controller {
    private let source: any EventSource
    /// Vendor-HID "original key" source (canon `&vkey`). Reads selectors
    /// off the Imprint dongle via IOHIDManager; started lazily in
    /// `loadConfig` only when the config declares a v-key trigger
    /// (`input = "<v-key-alias>"`), so non-vkey users are never prompted
    /// for Input Monitoring.
    private let vkeySource: VKeyHIDSource
    private var matcher: Matcher
    private var config: ChordConfig
    private var observers: [NSObjectProtocol] = []
    private var configWatcher: DispatchSourceFileSystemObject?
    /// Accept source for the read-only `chord query --…` socket.
    /// Internal (not private) so the QueryServer extension can install
    /// + tear it down; nil when the query API is disabled (bind failure).
    var querySource: DispatchSourceRead?

    public init(source: any EventSource = MacOSEventSource()) {
        self.source = source
        self.vkeySource = VKeyHIDSource()
        self.config = .init()
        self.matcher = Matcher(bindings: [], excludeApps: [])
    }

    public func start() throws {
        publishStartMeta()
        loadConfig(reason: "startup")
        FrontmostTracker.shared.start()
        InputSourceTracker.shared.start()

        // Strong, Sendable capture for the synchronous tap handler.
        let weakSelf = WeakWrap(self)
        try source.start { event in
            guard let me = weakSelf.value else { return .passthrough }
            return me.handle(event)
        }

        installControlIPC()
        installConfigWatcher()
        installQueryServer()
        Control.writeStatus("started bindings=\(matcher.bindings.count)")
    }

    public func stop() {
        source.stop()
        vkeySource.stop()
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
        }
        observers.removeAll()
        configWatcher?.cancel()
        configWatcher = nil
        teardownQueryServer()
        Control.writeStatus("stopped")
    }

    // MARK: - hot path

    nonisolated private func handle(_ event: InputEvent) -> EventOutcome {
        // The tap callback fires on its own run loop thread. We
        // snapshot `matcher` once (assignment is atomic enough at
        // value-type granularity in Swift) and act without
        // bouncing to main — main bounces would deadlock the tap.
        if isPaused() {
            emitWatch(event: event, outcome: "passthrough (paused)")
            return .passthrough
        }

        // Branch on event kind before consulting the matcher. The
        // matcher only deals with `.down` events; `.up` flows
        // through the pending-up table for paired consume + onUp
        // dispatch; `.modifiersChanged` flows through the hold-while
        // cleanup path and never reaches the matcher.
        switch event.kind {
        case .modifiersChanged:
            Log.debug("flagsChanged: mods=0x\(String(event.modifiers.rawValue, radix: 16))")
            for name in variableStore.clearStale(currentMods: event.modifiers) {
                Log.debug("state: clear \(name) (hold-while released)")
            }
            fireModifierOnlyBindings(currentMods: event.modifiers,
                                     bundleID: event.frontmostBundleID)
            emitWatch(event: event, outcome: "passthrough (modifiers-only event)")
            return .passthrough
        case .up:
            Log.debug("up: trigger=\(event.trigger) mods=0x\(String(event.modifiers.rawValue, radix: 16))")
            let outcome = handleKeyUp(trigger: event.trigger)
            emitWatch(event: event,
                      outcome: outcome == .consume ? "consume (paired up)"
                                                   : "passthrough (no pending up)")
            return outcome
        case .down:
            Log.debug("down: trigger=\(event.trigger) mods=0x\(String(event.modifiers.rawValue, radix: 16))")
            break
        }

        let snapshot = matcherSnapshot()
        let state = variableStore.snapshot()
        let me = Matcher.Event(trigger: event.trigger,
                               modifiers: event.modifiers,
                               bundleID: event.frontmostBundleID,
                               state: state,
                               inputSourceID: event.inputSourceID)
        guard let binding = snapshot.find(me) else {
            emitWatch(event: event, outcome: "passthrough (no match)")
            return .passthrough
        }
        // chord 0.9.0+ autorepeat strategy. macOS emits `keyDown` with
        // the autorepeat flag set while a key is held; without a
        // strategy, every typematic tick re-fires the action (a long
        // press on `action-shell` would spam shell invocations).
        // `.fireEach` (default) reproduces the pre-0.9.0 behaviour.
        if event.isRepeat {
            switch binding.repeatStrategy {
            case .fireEach: break  // fall through to the dispatch below
            case .ignore:
                // Consume so the OS doesn't see a phantom repeat for
                // a key whose initial down we already swallowed.
                emitWatch(event: event,
                          outcome: "consume (repeat ignored, match='\(binding.name)')")
                return .consume
            case .passthrough:
                emitWatch(event: event,
                          outcome: "passthrough (repeat, match='\(binding.name)')")
                return .passthrough
            }
        }
        // Intercept state-mutating actions: state ownership lives here,
        // not in the dispatcher (which is in the Adapter layer and has
        // no legitimate reason to know about the controller's store).
        switch binding.action {
        case .setVariable(let name, let value):
            variableStore.set(name: name, value: value,
                              holdWhile: binding.holdWhile,
                              timeoutMs: binding.holdWhileTimeoutMs)
            Log.debug("state: set \(name)=\(value) " +
                      "via '\(binding.name)'" +
                      lifecycleTag(binding))
        case .toggleVariable(let name):
            // Flip 0↔1 atomically (single lock window) — any non-zero
            // value collapses to 0, matching the documented contract. The
            // live store is the source of truth, not the per-event snapshot.
            let (current, next) = variableStore.toggle(name: name)
            Log.debug("state: toggle \(name) \(current)→\(next) " +
                      "via '\(binding.name)'")
        case .keys, .shell, .noop:
            ActionDispatcher.dispatch(binding)
        }
        // Karabiner-style multi-action on down: run any extra actions
        // (only `.keys`, per the parser) in order, right after the
        // primary. Swap `.action` and re-dispatch — same trick the
        // on-up path uses; the dispatcher only reads `.action`.
        for extra in binding.extraDownActions {
            var b = binding
            b.action = extra
            ActionDispatcher.dispatch(b)
        }
        // B-α reset-on-use: any binding gated on a variable extends
        // that variable's inactivity timer. Runs AFTER the primary
        // action so a setVariable + reset on the same binding still
        // ends in a fresh timer. (Self-gate is rare but possible.)
        if case .variable(let gated, _) = binding.condition {
            variableStore.extendTimer(name: gated)
        }
        recordFire(name: binding.name, app: event.frontmostBundleID,
                   action: describeAction(binding.action))
        Control.writeStatus("fired \(binding.name)")
        // chord 0.9.0+ passthrough: action fires above, but we let the
        // original event reach the OS. No paired-up to capture (the
        // OS sees both down + up natively), so skip the pendingUps
        // registration too. action-keys / on-up / noop are forbidden
        // on passthrough bindings at parse time, so reaching here is
        // shell / setVariable only.
        if binding.passthrough {
            emitWatch(event: event,
                      outcome: "passthrough (match='\(binding.name)' passthrough=true)")
            return .passthrough
        }
        // Register pairing: B1 contract — the OS never saw this
        // down, so the corresponding up must also be consumed.
        // The binding (with its onUpAction) is what handleKeyUp
        // dispatches against.
        registerPendingUp(trigger: event.trigger, binding: binding)
        emitWatch(event: event,
                  outcome: "consume (match='\(binding.name)' action=\(describeAction(binding.action)))")
        return .consume
    }

    /// Compact action description for `chord daemon --watch` lines.
    /// Sourced from [Action.kindString] (same discriminator the wire
    /// schema emits) so the watch log and `--json` never diverge.
    nonisolated private func describeAction(_ a: Action) -> String {
        a.kindString
    }

    /// One-line structured per-event log for `chord daemon --watch`. Emits
    /// to `/tmp/chord-watch.log` only when the file exists (= a watch
    /// client has been started). Format:
    /// ```
    /// event(<kind>, trigger=<…>, mods=0x<hex>, app=<bundle-id>) → <outcome>
    /// ```
    nonisolated private func emitWatch(event: InputEvent, outcome: String) {
        let kind: String
        switch event.kind {
        case .down:
            kind = event.isRepeat ? "down-repeat" : "down"
        case .up:
            kind = "up"
        case .modifiersChanged:
            kind = "modsChanged"
        }
        let mods = String(event.modifiers.rawValue, radix: 16)
        let app = event.frontmostBundleID ?? "?"
        let isrc = event.inputSourceID.map { ", input-source=\($0)" } ?? ""
        Log.watch("event(\(kind), trigger=\(event.trigger), " +
                  "mods=0x\(mods), app=\(app)\(isrc)) → \(outcome)")
    }

    /// Format the lifecycle suffix for the state-set log line.
    /// Branches on which lifecycle the binding picked; the parser
    /// has already enforced the hold-while / hold-while-timeout
    /// exclusivity so at most one branch is non-nil.
    nonisolated private func lifecycleTag(_ b: Binding) -> String {
        if let m = b.holdWhile {
            return " (hold-while=0x\(String(m.rawValue, radix: 16)))"
        }
        if let ms = b.holdWhileTimeoutMs {
            return " (timeout=\(ms)ms)"
        }
        return ""
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
                variableStore.set(name: name, value: value,
                                  holdWhile: binding.holdWhile,
                                  timeoutMs: binding.holdWhileTimeoutMs)
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

    /// Wipe all daemon state on config reload — the new config may have
    /// dropped a binding that owned a variable, leaving state nothing can
    /// ever clear. Clean slate on reload sidesteps the leak (and matches
    /// the user's mental model: "reload restarts the daemon's state").
    nonisolated private func resetState() {
        variableStore.reset()
        pendingUpsLock.lock()
        pendingUps = nil
        pendingUpsLock.unlock()
        // chord 0.9.0+: also reset the modifier-only baseline so a
        // reload doesn't spuriously fire entry actions for masks that
        // were already in effect before the reload.
        prevModsLock.lock()
        sharedPrevMods = []
        prevModsLock.unlock()
        // Drop any held-vkey edge latch so a reload starts clean (the
        // published Matcher already carries the new vkey bindings; this
        // only resets the press/release latch the HID callback reads).
        vkeyLock.lock()
        lastVKeyDown = 0
        vkeyLock.unlock()
    }

    /// chord 0.9.0+ modifier-only triggers. Walks all bindings with
    /// `trigger == .modifiersOnly` and fires entry / exit actions based
    /// on the transition `prevMods → currentMods`:
    ///   * `!prev satisfied && curr satisfied` → primary `action`
    ///   * `prev satisfied && !curr satisfied` → `onUpAction` if any
    /// Apps + condition filters still apply. Extras / passthrough do
    /// not (modifier-only events never reach the consume/passthrough
    /// decision — the tap callback always returns `.passthrough` on
    /// `.modifiersChanged`).
    nonisolated private func fireModifierOnlyBindings(
        currentMods: Modifiers, bundleID: String?
    ) {
        let prev: Modifiers
        prevModsLock.lock()
        prev = sharedPrevMods
        sharedPrevMods = currentMods
        prevModsLock.unlock()
        guard prev != currentMods else { return }

        let snapshot = matcherSnapshot()
        let state = variableStore.snapshot()
        for b in snapshot.bindings where b.trigger == .modifiersOnly {
            // App scope.
            if let apps = b.apps {
                guard let id = bundleID else { continue }
                if !Matcher.appsAllow(id, patterns: apps) { continue }
            }
            // Condition gate.
            if let cond = b.condition,
               !Matcher.conditionHolds(cond, state: state)
            {
                continue
            }
            let prevSat = b.modifiers.matches(event: prev)
            let curSat  = b.modifiers.matches(event: currentMods)
            if !prevSat && curSat {
                fireBindingAction(b, isOnUp: false)
                Log.debug("modifiers-only entry: '\(b.name)'")
            } else if prevSat && !curSat, let onUp = b.onUpAction {
                var upBinding = b
                upBinding.action = onUp
                fireBindingAction(upBinding, isOnUp: true)
                Log.debug("modifiers-only exit: '\(b.name)' (onUp)")
            }
        }
    }

    /// Internal: run the binding's action with the same state-mutation
    /// interception logic as the regular .down path (Controller owns
    /// state; the dispatcher only handles keys / shell / noop).
    nonisolated private func fireBindingAction(
        _ binding: Binding, isOnUp: Bool
    ) {
        switch binding.action {
        case .setVariable(let name, let value):
            variableStore.set(name: name, value: value,
                              holdWhile: binding.holdWhile,
                              timeoutMs: binding.holdWhileTimeoutMs)
        case .toggleVariable(let name):
            variableStore.toggle(name: name)
        case .keys, .shell, .noop:
            ActionDispatcher.dispatch(binding)
        }
    }

    // MARK: - vkey (vendor-HID) hot path

    /// A vendor-HID selector arrived from [VKeyHIDSource] (on the main run
    /// loop). It is normalised into an `InputEvent` carrying a `.vkey(id)`
    /// trigger and fed through the SAME `handle(_:)` path the CGEventTap
    /// uses, so a vkey binding (`input = "<v-key-alias>"`) gets the full
    /// Matcher (apps / when-var / on-up), pendingUps pairing, recordFire
    /// and pause handling for free — no separate dispatch path.
    ///
    /// Firmware contract: `selector` is the pressed id `1...255`, or `0`
    /// on release. One report per edge, so a press is a `.down` of
    /// `.vkey(id)` and a release is the `.up` of the previously-held id
    /// (the release report carries no id, hence the `lastVKeyDown` latch).
    /// A same-id repeat is ignored; an `A → B` roll (a fresh id before the
    /// `0`) releases A then presses B.
    nonisolated private func handleVKey(selector: UInt8) {
        let bundle = FrontmostTracker.shared.bundleID
        let isrc = InputSourceTracker.shared.id

        vkeyLock.lock()
        let prev = lastVKeyDown
        if selector == prev {              // duplicate report / autorepeat
            vkeyLock.unlock()
            return
        }
        lastVKeyDown = selector            // track the wire even if paused
        vkeyLock.unlock()

        // Release the previously-held vkey first (covers 0=release and the
        // defensive A→B roll where no 0 was seen in between). `handle`
        // pairs this against the pendingUp registered on its down.
        if prev != 0 {
            _ = handle(InputEvent(trigger: .vkey(prev), modifiers: [],
                                  frontmostBundleID: bundle, kind: .up,
                                  inputSourceID: isrc))
        }
        // 0 is release-only — nothing to press.
        guard selector != 0 else { return }
        _ = handle(InputEvent(trigger: .vkey(selector), modifiers: [],
                              frontmostBundleID: bundle, kind: .down,
                              inputSourceID: isrc))
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

    nonisolated func isPaused() -> Bool {
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

    nonisolated func matcherSnapshot() -> Matcher {
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
                excludeApps: result.config.options.excludeApps,
                fnAutoArrows: result.config.options.fnAutoArrows)
            publishMatcher()
            publishConfigMeta(actionAliases: result.config.actionAliases.count,
                              inputAliases: result.config.inputAliases.count)
            // Reload wipes the variable store — the new config may
            // have removed the binding that owned a variable, and a
            // stale entry no one can clear would silently keep a
            // condition-gated binding alive.
            resetState()
            let undef = result.warnings.lazy
                .filter { $0.kind == .undefinedActionAlias }
                .count
            let hint = (result.droppedBindings > 0 || result.warnings.count > 0)
                ? " (run config --validate --strict for details)" : ""
            Log.line("config \(reason): \(matcher.bindings.count) bindings, " +
                     "\(matcher.fallbacks.count) fallbacks, " +
                     "\(result.config.actionAliases.count) action-aliases, " +
                     "undefined-action-aliases=\(undef), " +
                     "dropped=\(result.droppedBindings)\(hint)")
            // Snapshot the loaded state for `chord daemon --reload --dry-run`
            // to diff against on the next edit. Failures here are
            // non-fatal — the daemon keeps running, dry-run just
            // shows everything as "added" until the next reload.
            saveLoadedSnapshot(result: result)
            // Bring the vendor-HID source up if (and only if) this config
            // declares a vkey-triggered binding. Idempotent — safe to call
            // on startup and every reload; the first config that adds a
            // vkey installs it, later reloads are no-ops.
            maybeStartVKeySource()
        } catch {
            Log.line("config \(reason) error: \(error)")
        }
    }

    /// True when the loaded config has any `.vkey` / `.anyVKey` trigger
    /// (a `input = "<v-key-alias>"` binding or the `v-key` wildcard
    /// fallback). Gates the IOHIDManager install so non-vkey users are
    /// never opened against the device / prompted for Input Monitoring.
    private func configDeclaresVKeys() -> Bool {
        func isVKey(_ t: Trigger) -> Bool {
            switch t {
            case .vkey, .anyVKey: return true
            default: return false
            }
        }
        return matcher.bindings.contains { isVKey($0.trigger) }
            || matcher.fallbacks.contains { isVKey($0.trigger) }
    }

    /// Start the vendor-HID source on the first reload that declares a
    /// vkey trigger. Failure is non-fatal: the core CGEventTap daemon keeps
    /// running, vkeys are simply disabled until Input Monitoring is granted.
    private func maybeStartVKeySource() {
        guard configDeclaresVKeys() else { return }
        let weakSelf = WeakWrap(self)
        do {
            try vkeySource.start { selector in
                weakSelf.value?.handleVKey(selector: selector)
            }
        } catch {
            Log.line(
                "vkey: Input Monitoring unavailable — \(error). Vendor-HID "
                + "keys disabled (grant chord under System Settings → Privacy "
                + "& Security → Input Monitoring, then `chord daemon --reload`). "
                + "Daemon continues.")
            // Surface the system prompt so the user can act on it.
            Permissions.promptForInputMonitoring()
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
final class WeakWrap: @unchecked Sendable {
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
// `chord daemon --pause` / `daemon --resume`.
nonisolated(unsafe) private var pausedFlag: Bool = false
private let pauseLock = NSLock()

// v2 state store. The variable dictionary, its lock, and the B-α
// inactivity timers now live in ChordCore's `VariableStore` (directly
// unit-tested). The daemon injects a DispatchSource-backed scheduler;
// the store is internally thread-safe (its own NSLock), so the tap
// thread and the vkey HID callback share it without further isolation.
let variableStore = VariableStore(scheduler: DispatchStateScheduler())

/// Production [StateScheduler]: a one-shot `DispatchSourceTimer` on a
/// dedicated serial queue (replaces the old `sharedTimers` /
/// `stateTimerQueue` globals).
struct DispatchStateScheduler: StateScheduler {
    private static let queue = DispatchQueue(label: "chord.state.timer",
                                             qos: .userInitiated)
    func schedule(afterMs: Int,
                  _ fire: @escaping @Sendable () -> Void) -> StateSchedulerToken {
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + .milliseconds(afterMs))
        timer.setEventHandler(handler: fire)
        timer.resume()
        return DispatchTimerToken(timer)
    }
}

/// Cancelable wrapping a `DispatchSourceTimer` (non-Sendable, hence
/// `@unchecked` — `cancel()` is safe to call from any thread).
final class DispatchTimerToken: StateSchedulerToken, @unchecked Sendable {
    private let timer: DispatchSourceTimer
    init(_ timer: DispatchSourceTimer) { self.timer = timer }
    func cancel() { timer.cancel() }
}

/// chord 0.9.0+ modifier-only trigger support: the last observed
/// OS modifier mask, used to detect mask-entry / mask-exit transitions
/// against each `Binding.trigger == .modifiersOnly` row. Updated on
/// every `.modifiersChanged` event before firing the corresponding
/// bindings. NSLock-guarded same as pendingUps — tap thread is the
/// sole writer.
nonisolated(unsafe) var sharedPrevMods: Modifiers = []
let prevModsLock = NSLock()

// Pending-up table: tap-side bookkeeping for the B1 contract
// (consume the up of every consumed down so the OS sees a coherent
// down/up pair, where it actually saw neither). Keyed by Trigger
// alone — the modifier mask may have changed by the time the
// release arrives (user lifts cmd before lifting the primary key).
nonisolated(unsafe) var pendingUps: [Trigger: Binding]?
let pendingUpsLock = NSLock()

// vkey (vendor-HID) press/release edge latch. The release report carries
// no id, so `lastVKeyDown` (0 = nothing held) remembers which `.vkey(id)`
// to synthesise the `.up` for. Touched by the HID callback (main run loop)
// and cleared on reload — same nonisolated(unsafe)+NSLock idiom as
// sharedMatcher / pendingUps above.
nonisolated(unsafe) private var lastVKeyDown: UInt8 = 0
private let vkeyLock = NSLock()

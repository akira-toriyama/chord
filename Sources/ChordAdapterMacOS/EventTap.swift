import AppKit
import ChordCore
import CoreGraphics
import Foundation

/// CGEventTap-backed event source. Sole place in the codebase that
/// touches `CGEventTap*` / `CGEvent` / `CFMachPort` APIs.
///
/// Critical contract: the tap callback runs on the tap's own run
/// loop and *must* return synchronously with consume / pass. The
/// `EventSource.start(handler:)` closure is called inline from that
/// callback.
///
/// Re-entrancy: `ActionDispatcher.postKeys` posts synthetic events
/// via `.cghidEventTap`, which means our own tap sees them. To
/// avoid an infinite loop we tag every synthetic event with
/// [syntheticUserData] in its `.eventSourceUserData` field and
/// short-circuit on the way back in.
public final class MacOSEventSource: EventSource, @unchecked Sendable {
    /// One bit chord owns in `kCGEventSourceUserData` — set on
    /// every synthetic event the dispatcher posts, checked on the
    /// way back into the tap.
    public static let syntheticUserData: Int64 = 0x43_48_4F_52_44_00 // 'CHORD\0'

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Strongly-held handler reference shared with the C callback
    /// via Unmanaged.
    private var handler: (@Sendable (InputEvent) -> EventOutcome)?

    public init() {}

    @MainActor
    public func start(
        handler: @escaping @Sendable (InputEvent) -> EventOutcome
    ) throws {
        if tap != nil {
            Log.line("event-tap: already installed")
            return
        }
        self.handler = handler

        let mask: CGEventMask =
              (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: MacOSEventSource.tapCallback,
            userInfo: info
        ) else {
            Log.line("event-tap: tapCreate failed — Accessibility not granted?")
            throw EventTapError.tapCreateFailed
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = src
        Log.line("event-tap: installed (mask=0x\(String(mask, radix: 16)))")
    }

    @MainActor
    public func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
        }
        tap = nil
        runLoopSource = nil
        handler = nil
        Log.line("event-tap: stopped")
    }

    // MARK: - callback

    private static let tapCallback: CGEventTapCallBack = {
        proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<MacOSEventSource>
            .fromOpaque(refcon).takeUnretainedValue()

        // Re-enable our tap if the system disabled it (most often
        // because the callback overran the watchdog deadline).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = me.tap {
                CGEvent.tapEnable(tap: port, enable: true)
                Log.line("event-tap: re-enabled after \(type.rawValue)")
            }
            return Unmanaged.passUnretained(event)
        }

        // Skip events we posted ourselves.
        if event.getIntegerValueField(.eventSourceUserData)
            == MacOSEventSource.syntheticUserData {
            return Unmanaged.passUnretained(event)
        }

        guard let handler = me.handler,
              let input = me.makeInputEvent(from: event, type: type)
        else {
            return Unmanaged.passUnretained(event)
        }

        switch handler(input) {
        case .passthrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        }
    }

    // MARK: - CGEvent → InputEvent

    private func makeInputEvent(
        from event: CGEvent, type: CGEventType
    ) -> InputEvent? {
        let mods = readModifiers(event.flags)
        let frontmost = FrontmostTracker.shared.bundleID

        switch type {
        case .keyDown:
            let raw = event.getIntegerValueField(.keyboardEventKeycode)
            // Strip the modifier bits from the modifiers we expose
            // to bindings — the raw flag mask includes the
            // numeric-keypad / device-dependent bits we don't
            // bind on. (Already handled by readModifiers.)
            return InputEvent(
                trigger: .key(UInt16(truncatingIfNeeded: raw)),
                modifiers: mods,
                frontmostBundleID: frontmost
            )

        case .flagsChanged:
            // Pure modifier presses (e.g. tapping just `fn`) are
            // not chord-triggers in v0. Pass through.
            return nil

        case .leftMouseDown:
            return InputEvent(trigger: .mouseButton(.left),
                              modifiers: mods,
                              frontmostBundleID: frontmost)
        case .rightMouseDown:
            return InputEvent(trigger: .mouseButton(.right),
                              modifiers: mods,
                              frontmostBundleID: frontmost)
        case .otherMouseDown:
            let n = event.getIntegerValueField(.mouseEventButtonNumber)
            let btn = MouseButton(rawValue: Int(n)) ?? .middle
            return InputEvent(trigger: .mouseButton(btn),
                              modifiers: mods,
                              frontmostBundleID: frontmost)

        case .scrollWheel:
            // Wheel deltas: positive Y = up, positive X = right
            // (CoreGraphics convention; same as the trackpad).
            let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let dir: ScrollDirection
            if abs(dy) >= abs(dx) {
                if dy == 0 { return nil }
                dir = dy > 0 ? .up : .down
            } else {
                if dx == 0 { return nil }
                dir = dx > 0 ? .right : .left
            }
            return InputEvent(trigger: .scroll(dir),
                              modifiers: mods,
                              frontmostBundleID: frontmost)

        default:
            return nil
        }
    }

    private func readModifiers(_ flags: CGEventFlags) -> Modifiers {
        var m: Modifiers = []
        if flags.contains(.maskCommand)        { m.insert(.cmd) }
        if flags.contains(.maskAlternate)      { m.insert(.opt) }
        if flags.contains(.maskControl)        { m.insert(.ctrl) }
        if flags.contains(.maskShift)          { m.insert(.shift) }
        if flags.contains(.maskSecondaryFn)    { m.insert(.fn) }
        return m
    }
}

public enum EventTapError: Error, CustomStringConvertible {
    case tapCreateFailed
    public var description: String {
        "CGEventTap creation failed — grant chord Accessibility access and retry"
    }
}

/// Public re-export so adapter code outside this file (the
/// dispatcher) can refer to the sentinel without knowing the type.
public enum EventTap {
    public static let syntheticUserData = MacOSEventSource.syntheticUserData
}

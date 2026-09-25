import ChordCore
import Foundation
import IOKit
import IOKit.hid

/// Vendor-defined HID source: v-keys and the split battery level.
///
/// Reads the canon firmware's vendor reports (Usage Page `0xFF31`) straight
/// off the Imprint USB dongle via `IOHIDManager` and routes each by report
/// ID to its own sink: `0x20`, the 1-byte v-key selector, to the Controller's
/// v-key path; `0x21` (chord 3.1.0+), the split peripheral battery level
/// `{source, level}`, to the `[battery]` watch. Deliberately NOT an
/// [EventSource] conformer: vendor reports never reach the CGEventTap, so
/// there is no consume / passthrough decision to make — the callbacks just
/// surface the bytes and the Controller decides what they mean.
///
/// Wire contract (verified on real hardware, vkey Phase 2): macOS exposes
/// the dongle as ONE device (primary usage = keyboard) carrying every
/// report ID, so the `0xFF31` usage page is NOT matchable — the modern
/// HID stack does not surface it as a separate primary-usage device. The
/// manager matches by **VID/PID**, which is ZMK's default pair and thus
/// shared by every ZMK-built device, and `deviceMatched` then admits only
/// the device whose USB product string is [productName] (measured
/// 2026-09-24: the fleet's ist dongle enumerated on this Mac with the same
/// VID/PID, which a VID/PID-only match arms too). Input reports arrive
/// as `[0x20, selector]` (the report-ID byte is included at `report[0]`);
/// the selector is `report[1]`. `selector == 0` means release.
///
/// Threading: `start()` / `stop()` are `@MainActor`; the `IOHIDManager`
/// is scheduled on the main run loop (the one `NSApplication.run()`
/// pumps), so the device-matching, removal and input-report callbacks fire
/// on the **main thread**. Every field is therefore touched on the main
/// thread only (start/stop on the main actor, callbacks on the main run
/// loop) — the `@unchecked Sendable` conformance documents that invariant,
/// the same discipline [MacOSEventSource] uses. The handler is held
/// strongly and reached from the C callbacks via an unretained `self`
/// pointer; the Controller owns this source for the daemon's lifetime so
/// the pointer never dangles.
public final class VKeyHIDSource: @unchecked Sendable {
    /// ZMK's default USB identity (`zmk/app/Kconfig`: `USB_DEVICE_VID` /
    /// `USB_DEVICE_PID`). Every ZMK-built device carries it — the fleet's
    /// ist dongle (zmk-ble-hid-host) included — so it only narrows IOKit's
    /// enumeration; [productName] does the identification.
    public static let vendorID = 0x1D50
    public static let productID = 0x615E
    /// USB product string of the Cyboard `imprint_dongle` shield
    /// (`ZMK_KEYBOARD_NAME` → `USB_DEVICE_PRODUCT`; zmk-keyboards
    /// `boards/shields/imprint_dongle/Kconfig.defconfig`). The one property
    /// that singles the Imprint dongle out: the serial is Zephyr's HWINFO
    /// value substituted at run time (not knowable at build), and the
    /// `0xFF31` usage page is emitted by every firmware built with
    /// `CONFIG_ZMK_HID_VKEY=y`, ist's owner profile included. A rename of
    /// the shield's keyboard name must be mirrored here.
    public static let productName = "Imprint Dongle"
    /// Vendor "original key" report (canon `ZMK_HID_REPORT_ID_VKEY`).
    public static let reportID: UInt8 = 0x20
    /// Split peripheral battery level report (canon
    /// `ZMK_HID_REPORT_ID_SPLIT_BATTERY`, chord 3.1.0+): wire
    /// `[0x21, source, level]`, `source` = the dongle's peripheral slot
    /// index, `level` = percent as ZMK reports it — `0` is a disconnected
    /// half, not an empty one (the tracker in ChordCore knows).
    public static let batteryReportID: UInt8 = 0x21

    private var manager: IOHIDManager?

    /// Strongly-held sinks, shared with the C callbacks via an unretained
    /// `self` pointer. `handler` takes the v-key selector; `batteryHandler`
    /// the battery report's `(source, level)`.
    private var handler: (@Sendable (UInt8) -> Void)?
    private var batteryHandler: (@Sendable (UInt8, UInt8) -> Void)?

    /// One armed dongle: the device, the input-report buffer registered on
    /// it, and a label for the log. Keyed by the device's object identity,
    /// which is what the input-report callback's `sender` carries (IOKitUser
    /// `IOHIDDevice.c` passes the `IOHIDDeviceRef`), so every report is
    /// attributed to the device it came from and one from an unknown sender
    /// is dropped instead of being read as a selector. Two admitted dongles
    /// would both feed `handler` as one selector stream — one Imprint dongle
    /// per Mac is the assumption; the device is known here, so a per-device
    /// stream is only a handler-signature change away.
    private struct Slot {
        let device: IOHIDDevice
        let buffer: UnsafeMutableBufferPointer<UInt8>
        let label: String
    }
    private var slots: [ObjectIdentifier: Slot] = [:]

    /// Buffers of removed devices, parked for the next match rather than
    /// freed. Each buffer is sized from the device's
    /// `kIOHIDMaxInputReportSizeKey`, because IOKit copies
    /// `min(bufferLength, reportLength)` bytes into the registered buffer
    /// before it consults the callback (IOHIDFamily `IOHIDDeviceClass.m`,
    /// `valueAvailableCallback`) — a shorter buffer silently truncates every
    /// longer report. Nothing orders a report queued just before an unplug
    /// against the removal notification (both ride the main run loop on
    /// different ports), so no buffer is freed while the manager is open;
    /// all are released in `stop()`, after `IOHIDManagerClose`. Re-use keeps
    /// the sleep/replug-prone dongle from growing the pool: one dongle, one
    /// buffer, for the daemon's lifetime.
    private var spareBuffers: [UnsafeMutableBufferPointer<UInt8>] = []

    public init() {}

    /// Install the manager (once) and set the sinks. The Controller calls
    /// this on every config load, so the sinks are replaced even when the
    /// manager is already installed — every field is main-thread only (see
    /// the type doc), so a callback never observes a half-set pair.
    @MainActor
    public func start(
        handler: @escaping @Sendable (UInt8) -> Void,
        battery: (@Sendable (_ source: UInt8, _ level: UInt8) -> Void)? = nil
    ) throws {
        self.handler = handler
        self.batteryHandler = battery
        if manager != nil {
            Log.line("vkey-hid: already installed")
            return
        }

        let mgr = IOHIDManagerCreate(
            kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: VKeyHIDSource.vendorID,
            kIOHIDProductIDKey as String: VKeyHIDSource.productID
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            mgr, VKeyHIDSource.deviceMatchedCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(
            mgr, VKeyHIDSource.deviceRemovedCallback, ctx)
        // Same run loop + mode as the CGEventTap (Controller.start runs on
        // @MainActor, so this is the main run loop NSApplication.run pumps).
        // Matches — the initial enumeration included — are delivered on
        // this run loop, so `deviceMatched` must not depend on anything
        // `start()` sets after this point.
        IOHIDManagerScheduleWithRunLoop(
            mgr, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        // IOHIDManagerOpen opens every matched device and reports the FIRST
        // failure (IOHIDManager.c `__IOHIDManagerDeviceApplier` latches it),
        // and the VID/PID match also covers ZMK devices this source never
        // arms. With Input Monitoring granted a failure is one device's (a
        // client holding it seized, say) and every match callback still
        // carries its own device's open result, so keep going and let
        // `deviceMatched` report per device. Without the grant nothing can
        // open: tear down and throw so the Controller can prompt.
        guard r == kIOReturnSuccess || Permissions.isInputMonitoringTrusted() else {
            // Input Monitoring (kTCCServiceListenEvent) is a SEPARATE
            // permission from Accessibility, so a daemon that has
            // Accessibility can still be denied here. A failed open leaves
            // the manager open (it opened whatever it could), so tear it
            // down the same way `stop()` does before the buffers go.
            IOHIDManagerUnscheduleFromRunLoop(
                mgr, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            releaseBuffers()
            self.handler = nil
            self.batteryHandler = nil
            Log.line(
                String(
                    format: "vkey-hid: IOHIDManagerOpen failed (0x%08X) — "
                        + "Input Monitoring denied?", UInt32(bitPattern: r)))
            throw VKeyHIDError.openFailed(r)
        }
        self.manager = mgr
        if r != kIOReturnSuccess {
            Log.line(
                String(
                    format: "vkey-hid: IOHIDManagerOpen reported 0x%08X for a matched "
                        + "device — continuing, each device reports on its own match",
                    UInt32(bitPattern: r)))
        }
        Log.line(
            String(
                format: "vkey-hid: installed (matching VID=0x%04X PID=0x%04X "
                    + "product=\"%@\", reportIDs=0x%02X/0x%02X)",
                VKeyHIDSource.vendorID, VKeyHIDSource.productID,
                VKeyHIDSource.productName, Int(VKeyHIDSource.reportID),
                Int(VKeyHIDSource.batteryReportID)))
    }

    @MainActor
    public func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            mgr, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        releaseBuffers()
        manager = nil
        handler = nil
        batteryHandler = nil
        Log.line("vkey-hid: stopped")
    }

    /// Frees every buffer, armed or parked. Only after the manager is closed
    /// (or its open failed) — see [spareBuffers].
    private func releaseBuffers() {
        for slot in slots.values { slot.buffer.deallocate() }
        slots.removeAll()
        for buffer in spareBuffers { buffer.deallocate() }
        spareBuffers.removeAll()
    }

    /// A VID/PID match appeared — admit it only if it is the Imprint dongle,
    /// then register an input-report buffer sized for the device so its
    /// reports reach `inputReportCallback`. Runs on the main run loop; a
    /// replug is a removal followed by a fresh match (a new device object).
    ///
    /// `openResult` is what the manager got from `IOHIDDeviceOpen` for this
    /// device (IOHIDManager.c `__IOHIDManagerDeviceApplier` hands the match
    /// callback the open's return). With no dongle present at `start()`,
    /// `IOHIDManagerOpen` has nothing to open and succeeds, so a denied Input
    /// Monitoring grant first surfaces HERE, on the plug-in — the moment to
    /// say so and to raise the system prompt, not to drop the match silently.
    private func deviceMatched(_ device: IOHIDDevice, openResult: IOReturn) {
        let product: String? = VKeyHIDSource.property(device, kIOHIDProductKey)
        let serial: String = VKeyHIDSource.property(device, kIOHIDSerialNumberKey) ?? "?"
        guard product == VKeyHIDSource.productName else {
            Log.line(
                "vkey-hid: ignoring ZMK device \"\(product ?? "?")\" (serial \(serial)) "
                    + "— not \"\(VKeyHIDSource.productName)\"")
            return
        }
        let label = "\(VKeyHIDSource.productName) (serial \(serial))"
        guard openResult == kIOReturnSuccess else {
            Log.line(
                String(
                    format: "vkey-hid: %@ matched but could not be opened (0x%08X) — "
                        + "Input Monitoring denied? (grant chord under System Settings → "
                        + "Privacy & Security → Input Monitoring, then `chord daemon --reload`)",
                    label, UInt32(bitPattern: openResult)))
            if !Permissions.isInputMonitoringTrusted() {
                Permissions.promptForInputMonitoring()
            }
            return
        }
        let key = ObjectIdentifier(device)
        if let slot = slots[key] {
            Log.debug("vkey-hid: \(slot.label) matched again — already armed")
            return
        }
        let reported: Int? = VKeyHIDSource.property(device, kIOHIDMaxInputReportSizeKey)
        let maxLength: Int
        if let reported, reported > 0 {
            maxLength = reported
        } else {
            // Never observed (both ZMK dongles report 13). The longer vendor
            // report is the 3-byte battery one, so both still work off a
            // minimal buffer; anything longer is clamped, and ignored anyway.
            maxLength = 3
            Log.line("vkey-hid: \(label) reports no MaxInputReportSize — arming a 3-byte buffer")
        }
        let buffer = takeBuffer(capacity: maxLength)
        slots[key] = Slot(device: device, buffer: buffer, label: label)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer.baseAddress!, buffer.count,
            VKeyHIDSource.inputReportCallback, ctx)
        Log.line(
            "vkey-hid: matched \(label), input-report callback armed "
                + "(MaxInputReportSize=\(maxLength), buffer=\(buffer.count) B)")
    }

    /// An armed device went away. Its buffer is parked, not freed — see
    /// [spareBuffers].
    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let slot = slots.removeValue(forKey: ObjectIdentifier(device)) else {
            return
        }
        spareBuffers.append(slot.buffer)
        Log.line("vkey-hid: \(slot.label) removed")
    }

    /// A parked buffer that fits, else a fresh zeroed one. A spare too small
    /// for `capacity` stays parked: a descriptor that grew across a replug
    /// costs one extra buffer for the daemon's lifetime — see [spareBuffers]
    /// for why it is not freed instead.
    private func takeBuffer(capacity: Int) -> UnsafeMutableBufferPointer<UInt8> {
        if let i = spareBuffers.firstIndex(where: { $0.count >= capacity }) {
            return spareBuffers.remove(at: i)
        }
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0)
        return buffer
    }

    /// A report landed in an armed device's buffer. Only the two vendor
    /// reports are read; the dongle's keyboard / consumer / mouse reports
    /// share the callback (one per device, not per report ID) and are
    /// skipped here.
    ///
    /// IOHIDDeviceRegisterInputReportCallback delivers the report-ID byte at
    /// report[0], so the payload starts at report[1] (verified on hardware:
    /// wire = [0x20, selector] / [0x21, source, level]). Anything shorter
    /// than its report can only be a copy clamped by an undersized buffer —
    /// IOKit never strips the ID on this path — and is dropped rather than
    /// misread.
    private func inputReport(
        from device: IOHIDDevice, reportID: UInt32, report: UnsafeBufferPointer<UInt8>
    ) {
        guard let slot = slots[ObjectIdentifier(device)] else {
            // Only a report that was queued before its device's removal can
            // land here; bounded by that device's queue, so per-event logging.
            Log.debug("vkey-hid: report from a device that is not armed — dropped")
            return
        }
        switch reportID {
        case UInt32(VKeyHIDSource.reportID):
            guard report.count >= 2 else { return }
            let selector = report[1]
            Log.debug("vkey-hid: selector=\(selector) from \(slot.label)")
            handler?(selector)
        case UInt32(VKeyHIDSource.batteryReportID):
            guard report.count >= 3 else { return }
            let source = report[1]
            let level = report[2]
            // Always logged, not debug-gated: a half's level changes a few
            // times an hour at most, and the log is the only place the
            // levels are visible (chord draws nothing).
            Log.line("vkey-hid: battery source=\(source) level=\(level)% from \(slot.label)")
            batteryHandler?(source, level)
        default:
            return
        }
    }

    private static func property<T>(_ device: IOHIDDevice, _ key: String) -> T? {
        IOHIDDeviceGetProperty(device, key as CFString) as? T
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = {
        ctx, result, _, device in
        guard let ctx else { return }
        let me = Unmanaged<VKeyHIDSource>.fromOpaque(ctx).takeUnretainedValue()
        me.deviceMatched(device, openResult: result)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = {
        ctx, _, _, device in
        guard let ctx else { return }
        let me = Unmanaged<VKeyHIDSource>.fromOpaque(ctx).takeUnretainedValue()
        me.deviceRemoved(device)
    }

    private static let inputReportCallback: IOHIDReportCallback = {
        ctx, result, sender, _, reportID, report, reportLength in
        guard let ctx, let sender, result == kIOReturnSuccess else { return }
        let me = Unmanaged<VKeyHIDSource>.fromOpaque(ctx).takeUnretainedValue()
        // `sender` is the IOHIDDeviceRef the report came from (IOKitUser
        // IOHIDDevice.c, `__IOHIDDeviceInputReportCallback`); the SDK header
        // only calls it "the interface instance sending the completion".
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        me.inputReport(
            from: device, reportID: reportID,
            report: UnsafeBufferPointer(start: report, count: reportLength))
    }
}

public enum VKeyHIDError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    public var description: String {
        switch self {
        case .openFailed(let r):
            return String(
                format: "IOHIDManagerOpen failed (0x%08X) — grant chord "
                    + "Input Monitoring access", UInt32(bitPattern: r))
        }
    }
}

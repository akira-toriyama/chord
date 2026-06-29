import ChordCore
import Foundation
import IOKit
import IOKit.hid

/// Vendor-defined HID "original key" (vkey) source.
///
/// Reads the canon firmware's vendor report (Usage Page `0xFF31`, Report
/// ID `0x20`) straight off the Imprint USB dongle via `IOHIDManager` and
/// hands the 1-byte selector to the Controller. Deliberately NOT an
/// [EventSource] conformer: vendor reports never reach the CGEventTap, so
/// there is no consume / passthrough decision to make — the callback just
/// surfaces the selector and the Controller maps `id → action`.
///
/// Wire contract (verified on real hardware, vkey Phase 2): macOS exposes
/// the dongle as ONE device (primary usage = keyboard) carrying every
/// report ID, so we match by **VID/PID** — NOT by the `0xFF31` usage page,
/// which the modern HID stack does not surface as a separate
/// primary-usage device. Input reports arrive as `[0x20, selector]` (the
/// report-ID byte is included at `report[0]`); the selector is
/// `report[1]`. `selector == 0` means release.
///
/// Threading: `start()` / `stop()` are `@MainActor`; the `IOHIDManager`
/// is scheduled on the main run loop (the one `NSApplication.run()`
/// pumps), so the device-matching and input-report callbacks fire on the
/// **main thread**. Every field is therefore touched on the main thread
/// only (start/stop on the main actor, callbacks on the main run loop) —
/// the `@unchecked Sendable` conformance documents that invariant, the
/// same discipline [MacOSEventSource] uses. The handler is held strongly
/// and reached from the C callbacks via an unretained `self` pointer; the
/// Controller owns this source for the daemon's lifetime so the pointer
/// never dangles.
public final class VKeyHIDSource: @unchecked Sendable {
    /// Cyboard Imprint dongle (canon `assimilator-bt`, XIAO BLE central).
    public static let vendorID = 0x1D50
    public static let productID = 0x615E
    /// Vendor "original key" report (canon `ZMK_HID_REPORT_ID_VKEY`).
    public static let reportID: UInt8 = 0x20

    /// Largest report we expect is 2 bytes (`[0x20, selector]`);
    /// over-allocate a little for safety.
    private static let reportBufferLength = 8

    private var manager: IOHIDManager?

    /// Strongly-held selector sink, shared with the C callbacks via an
    /// unretained `self` pointer.
    private var handler: (@Sendable (UInt8) -> Void)?

    /// Single input-report scratch buffer, allocated once in `start()` and
    /// registered for every matched device (re-registered on a replug —
    /// the dongle is sleep/replug-prone). One buffer is safe because all
    /// reports are delivered serially on the one main run loop and consumed
    /// synchronously in the callback, and the dongle enumerates as a single
    /// device. Re-using it (vs. one-per-match) avoids leaking a buffer on
    /// every USB re-enumeration. Freed once in `stop()`.
    private var reportBuffer: UnsafeMutableBufferPointer<UInt8>?

    public init() {}

    @MainActor
    public func start(handler: @escaping @Sendable (UInt8) -> Void) throws {
        if manager != nil {
            Log.line("vkey-hid: already installed")
            return
        }
        self.handler = handler

        // Allocate the shared report buffer before opening — IOHIDManagerOpen
        // can fire matching callbacks synchronously for already-connected
        // devices, and deviceMatched needs the buffer to register against.
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(
            capacity: VKeyHIDSource.reportBufferLength)
        buf.initialize(repeating: 0)
        self.reportBuffer = buf

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
        // Same run loop + mode as the CGEventTap (Controller.start runs on
        // @MainActor, so this is the main run loop NSApplication.run pumps).
        IOHIDManagerScheduleWithRunLoop(
            mgr, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            // Most common cause: Input Monitoring (kTCCServiceListenEvent)
            // not granted — a SEPARATE permission from Accessibility, so a
            // daemon that has Accessibility can still be denied here.
            IOHIDManagerUnscheduleFromRunLoop(
                mgr, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            reportBuffer?.deallocate()
            reportBuffer = nil
            self.handler = nil
            Log.line(
                String(
                    format: "vkey-hid: IOHIDManagerOpen failed (0x%08X) — "
                        + "Input Monitoring denied?", UInt32(bitPattern: r)))
            throw VKeyHIDError.openFailed(r)
        }
        self.manager = mgr
        Log.line(
            String(
                format: "vkey-hid: installed (matching VID=0x%04X PID=0x%04X, "
                    + "reportID=0x%02X)",
                VKeyHIDSource.vendorID, VKeyHIDSource.productID,
                Int(VKeyHIDSource.reportID)))
    }

    @MainActor
    public func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            mgr, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer?.deallocate()
        reportBuffer = nil
        manager = nil
        handler = nil
        Log.line("vkey-hid: stopped")
    }

    // MARK: - device matching

    /// A matching device appeared — register the shared input-report buffer
    /// so its reports reach `inputReportCallback`. Runs on the main run loop;
    /// re-fires (and re-registers the same buffer) on every replug.
    private func deviceMatched(_ device: IOHIDDevice) {
        guard let buf = reportBuffer else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buf.baseAddress!, buf.count,
            VKeyHIDSource.inputReportCallback, ctx)
        Log.debug("vkey-hid: matched Imprint device, input-report callback armed")
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = {
        ctx, result, _, device in
        guard let ctx, result == kIOReturnSuccess else { return }
        let me = Unmanaged<VKeyHIDSource>.fromOpaque(ctx).takeUnretainedValue()
        me.deviceMatched(device)
    }

    // MARK: - input report

    private static let inputReportCallback: IOHIDReportCallback = {
        ctx, result, _, _, reportID, report, reportLength in
        guard let ctx, result == kIOReturnSuccess,
            reportID == UInt32(VKeyHIDSource.reportID), reportLength >= 1
        else { return }
        let me = Unmanaged<VKeyHIDSource>.fromOpaque(ctx).takeUnretainedValue()
        // IOHIDDeviceRegisterInputReportCallback delivers the report-ID
        // byte at report[0], so the 1-byte selector is report[1] (verified
        // on hardware: wire = [0x20, selector]). Fall back to report[0]
        // for a hypothetical ID-stripped delivery.
        let selector: UInt8 = reportLength >= 2 ? report[1] : report[0]
        me.handler?(selector)
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

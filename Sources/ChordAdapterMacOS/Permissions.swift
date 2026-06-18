import ApplicationServices
import Foundation
import IOKit.hid

/// CGEventTap installation requires Accessibility (and posting
/// synthetic keys requires the same). Bundling the prompt + the
/// status check here so the rest of the adapter doesn't sprout
/// `kAXTrusted*` references.
///
/// The vkey vendor-HID source ([VKeyHIDSource]) additionally needs
/// **Input Monitoring** (`kTCCServiceListenEvent`) — a SEPARATE TCC
/// permission from Accessibility. Its check / prompt live here too so
/// IOHID's `kIOHIDRequestType*` constants stay walled off in this file.
public enum Permissions {
    /// `kAXTrustedCheckOptionPrompt` is exposed as a `var` in the
    /// Swift overlay, which Swift 6 strict concurrency rejects.
    /// The underlying CFStringRef is documented to be the literal
    /// `"AXTrustedCheckOptionPrompt"`, so we use that directly —
    /// same workaround facet uses in the same spot.
    private static var promptOptionKey: CFString {
        "AXTrustedCheckOptionPrompt" as CFString
    }

    /// Currently trusted? Pure check — never prompts.
    public static func isAccessibilityTrusted() -> Bool {
        let opts: CFDictionary =
            [promptOptionKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Trigger the system prompt to add chord to Accessibility.
    /// If already trusted, the prompt is suppressed and this just
    /// returns true. The prompt's outcome is asynchronous — the
    /// user grants in System Settings and chord re-checks on next
    /// launch.
    @discardableResult
    public static func promptForAccessibility() -> Bool {
        let opts: CFDictionary =
            [promptOptionKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Input Monitoring (`kTCCServiceListenEvent`) currently granted?
    /// Pure check — never prompts. Needed by [VKeyHIDSource]; without it
    /// `IOHIDManagerOpen` fails (the v-key source treats that as denial,
    /// throws, and prompts) so v-keys stay dead until granted + reloaded.
    public static func isInputMonitoringTrusted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Trigger the system prompt to add chord to Input Monitoring. Like
    /// the Accessibility prompt the outcome is asynchronous — the user
    /// grants in System Settings and chord re-checks on the next reload.
    @discardableResult
    public static func promptForInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

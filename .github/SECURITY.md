# Security policy

## Threat model

`chord` taps every keystroke and pointer-button event the macOS
session produces. Its security posture is dominated by these facts:

1. **Accessibility access** is required and granted by the user
   in System Settings. chord never asks for it again at runtime
   except by triggering Apple's own prompt via
   `AXIsProcessTrustedWithOptions`.
2. **Shell actions execute arbitrary commands** under the user's
   account. The config file at `~/.config/chord/config.toml` is
   the source of truth for what runs; chord trusts its contents
   verbatim. Treat it the same way you treat `.zshrc` or
   `Brewfile`.
3. **Input Monitoring (conditional, v-key only)** — only when the
   config declares v-key bindings does chord open the canon dongle
   (matched by VID/PID) via `IOHIDManager` under the Input
   Monitoring grant (`kTCCServiceListenEvent`) and read one vendor
   usage page (`0xFF31`, report `0x20`). It subscribes to no other
   device and reads no general keyboard HID; non-v-key users are
   never prompted for it.

## What chord does NOT do

- It does not log keystrokes anywhere (only matched-binding names
  go to `/tmp/chord.log`).
- It does not phone home, fetch updates, or contact any network.
- It does not bypass the TCC accessibility prompt. If the prompt
  was suppressed by a third-party tool, chord still runs the
  permission check.
- It does not read HID reports from any device other than the
  matched canon dongle, and only that dongle's self-defined vendor
  page (never general keyboard HID).

## Reporting a vulnerability

Email or open a GitHub Security Advisory. Please **do not** file a
public issue with the details.

We respond within 7 days. If the issue is confirmed and fixable,
expect a patch + advisory within 30 days, faster for credential /
TCC-bypass classes.

## Supported versions

Until 1.0, only `main` is supported.

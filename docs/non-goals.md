# Non-Goals

Records the features chord **deliberately does not have**, and why. These were
all considered while surveying the neighboring projects
([skhd](https://github.com/koekeishiya/skhd) /
[skhd.zig](https://github.com/jackielii/skhd.zig) /
[Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements) /
[ZMK](https://zmk.dev)), and rejected against chord's design philosophy,
distributability, and USP.

Keeping them here instead of filing issues stops the same debates from
reigniting periodically.

## chord's USP (what the non-goals exist to protect)

- **Core lightness — one AX grant (the core)**: the core features run on the
  Accessibility permission alone. No DriverKit, no virtual HID device, no root
  daemon. **The single exception is the opt-in v-key**: to read the 1-byte
  selector canon firmware sends via `&vkey <id>` on vendor usage page
  `0xFF31` / report ID `0x20`, chord uses IOHIDManager + Input Monitoring
  (`kTCCServiceListenEvent`). The path starts only for users who write a
  v-key binding in their config (`Controller.maybeStartVKeySource` gates on
  `configDeclaresVKeys()`); non-v-key users never open IOHIDManager and are
  never prompted for Input Monitoring. **General HID interception /
  per-device routing / DriverKit remain non-goals.**
- **Single-CGEventTap simplicity**: synchronous first-match-wins. The
  contract is deciding consume / pass right inside the tap callback.
- **One human-readable TOML config**: no GUI, no code generation —
  `config.toml` is the single source of truth.
- **A narrow-surface state machine**: single-variable equality only, no
  nested modes. Complex state belongs to ZMK / Karabiner.

Anything that violates these is a **non-goal no matter how popular**. The one
exception is the v-key (above) — individually justified as an explicit
opt-in, least-privilege path that only reads a single vendor page from a
single device. It does not generalize (per-device routing / general HID
interception / DriverKit stay out).

---

## 1. mod-morph (behavior changes with modifier state)

*(reviewed 2026-05-31)*

**Origin**: ZMK `&mm` (mod-morph)

HID-layer remappers like ZMK often morph one physical key by modifier state
("`;` alone → `;` / shift+`;` → `:`"), because that layer has to deal with
modifier transparency anyway.

**chord does not need it.** chord runs at the CGEventTap layer and
**receives events after the OS has already interpreted the modifiers**. Type
`shift + semicolon` and the OS keymap produces `:`, which is what triggers
chord. To achieve the same thing, write two bindings:

```toml
[[bindings]] input = "semicolon"           action-keys = "..."
[[bindings]] input = "shift - semicolon"   action-keys = "..."
```

`[[remap]]` (#13) gives you the tabular DRY form. A dedicated mod-morph
feature buys little on top of that.

---

## 2. per-device (VID/PID) matching

*(reviewed 2026-05-31)*

**Origin**: [skhd.zig `.device`](https://github.com/jackielii/skhd.zig),
[Karabiner `device_if`](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/device/)

Branching **ordinary keys** by physical device (suppress on the built-in
keyboard, fire only from canon) **remains a non-goal**. The reason is a
design choice, not a technical impossibility:

- CGEventTap carries little more than `kCGKeyboardEventKeyboardType` (HID
  country code) and an eventSource ID — the physical device identity of an
  **ordinary event** has been stripped
- Getting it back means **subscribing to every HID report of ordinary
  keyboards via IOHIDManager** plus Karabiner-style HID/CGEvent correlation,
  or going through a DriverKit virtual HID
- Either one forfeits the single-tap consume/pass contract and the core's
  **"runs on one AX grant" lightness**

**How the v-key differs (important)**: chord does VID/PID-match the dongle
(`0x1D50`/`0x615E`) with IOHIDManager for v-keys, but it reads **only** the
1-byte selector on canon's self-defined vendor usage page (`0xFF31` /
report ID `0x20`) and never reads ordinary keyboard reports. So it is not
per-device routing of ordinary keys and needs no HID/CGEvent correlation.
The v-key is a narrow window — "one self-owned page from one device" — not
the per-device branching described here (the §USP exception).

Practically, a 3-modifier strict-side chord like ULTRA_LL is most likely
**physically impossible to press** on the built-in keyboard, so the
misfire rate is unmeasured to begin with.

**If it becomes necessary**: run Karabiner-Elements alongside (Karabiner does
the per-device filter → chord does the routing) — that is the right division
of labor. (The v-key's vendor-HID read is a separate thing — per-device
filtering of ordinary keys stays Karabiner's job.)

---

## 3. dead-key / F21-F24 origination (emitting from chord)

*(reviewed 2026-05-31)*

**Origin**: [Karabiner-Elements](https://karabiner-elements.pqrs.org/)'
DriverKit virtual HID device

chord can **interpret** (receive) F21-F24 / dead keys / consumer-page keys,
but cannot **originate** them (CGEvent.post):

- F21-F24 have no Apple-assigned `kVK_*` constants; CGEvent treats them as
  undefined keycodes
- Dead keys are composed in the OS keymap layer, so CGEvent can only carry
  the post-composition character
- Consumer-page keys (media keys etc.) are partly possible via `NSEvent`,
  but the hotkey-origination use case is thin

Implementing it would require IPC to Karabiner-VirtualHIDDevice-Daemon,
which means a DriverKit dependency = losing chord's USP.

**Use case first**: there is no concrete scenario where chord would emit
F21-F24 (the roles are settled: canon/ZMK is the emitter, chord the
receiver).

**If it becomes necessary**: run Karabiner-Elements alongside (Karabiner
emits at the HID layer → chord routes).

---

## 4. BLE / multi-host pairing

*(reviewed 2026-05-31)*

**Origin**: [ZMK Bluetooth subsystem](https://zmk.dev/docs/features/bluetooth)
(`&bt BT_SEL N` etc.)

ZMK firmware's territory. chord is a **macOS userland daemon** and cannot
participate in principle:

- BLE pairing state lives **inside the keyboard MCU**
- A host switch, seen from macOS, is a disconnect plus a reconnect to a
  different host — on the new host, chord is a different instance on a
  different OS
- The control authority is simply not on the macOS side

A peripheral feature like "detect BLE disconnect and auto-pause" is
conceivable, but that fits inside `chord daemon --watch` (#15) or a
`chord daemon --show` extension — not an independent issue's worth of scope.

---

## 5. JSON config format (Karabiner-style)

*(reviewed 2026-05-31)*

**Origin**: [Karabiner-Elements `karabiner.json`](https://karabiner-elements.pqrs.org/docs/manual/configuration/configuration-file-path/)

TOML alone is enough for chord. Adding JSON input support buys little:

- **Karabiner JSON cannot be reused anyway, semantically**: Karabiner's
  `complex_modifications.rules[].manipulators[].from/to/conditions[]` and
  chord's `[[bindings]]` structure are different things. Accepting JSON in
  form still leaves the conversion problem
- **TOML's human readability is part of chord's culture**: the comment
  density and the `[input-aliases]` / `[action-aliases]` tables of
  [private_config.toml](https://github.com/akira-toriyama/dotfiles/blob/main/chezmoi/dot_config/chord/private_config.toml)
  are pillars of the chord DSL's legibility
- **Two-format maintenance cost**: every new feature (`[[sequence]]` /
  `per-app` / `{{N}}`) would owe TOML + JSON support code
- **`config --show --json` already exists**: the machine-read use case is
  covered on the output side

**If you want machine generation**: emit TOML with Python `tomlkit` / Swift
`TOMLKit` or similar. JSON support on the input side is unnecessary.

---

## 6. HUD / visual mode indicator

*(reviewed 2026-06-06)*

**Origin**: [Karabiner-Elements notification window](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to/set_notification_message/) / [Hammerspoon `hs.alert`](https://www.hammerspoon.org/docs/hs.alert.html) / old issue #25

An on-screen overlay showing the current state on mode entry/exit or
state-var changes. **Not adopted** as part of the chord daemon:

- **Collision with the headless invariant**: chord is a headless
  `LSUIElement=true` daemon. Embedding an AppKit overlay window breaks the
  foundation of its distribution profile — no Dock, no Menu Bar, no GUI
  interference.
- **Adapter-layer bloat**: ChordAdapterMacOS is defined as the "touches the
  OS" layer limited to CGEventTap / AX / NSWorkspace / IOHIDManager (the
  v-key vendor-HID read) — see the `Package.swift` comment. Those are all
  *input / permission* surfaces; adding a *drawing* surface (NSWindow /
  NSAttributedString) diffuses the Adapter's responsibility boundary.
- **`action-shell` substitutes**: visual-notification use cases can be
  delegated externally today —
  `action-shell = "osascript -e 'display notification \"j-layer ON\"'"` /
  `terminal-notifier` / `hs -c "hs.alert.show(...)"`. The daemon itself
  needs no drawing responsibility.
- **Sound (`@play-undef` etc.) already gives equivalent immediate
  feedback**: extending the `play-undef` pattern in
  [private_config.toml](https://github.com/akira-toriyama/dotfiles/blob/main/chezmoi/dot_config/chord/private_config.toml)
  covers the non-visual feedback variations.

**If a visual HUD is truly needed**: write a separate process `chord-hud` as
an independent distributable that reads daemon state via
[`chord --query`](https://github.com/akira-toriyama/chord/issues/32) and
draws on its own — fully separated, outside the daemon's responsibility.

---

## When these become Yes

The conditions under which each non-goal **becomes worth reconsidering**:

| Non-goal | The condition for Yes |
|---|---|
| 1. mod-morph | A separate decision is made for chord to remap **ordinary keys** at the HID layer (DriverKit virtual HID). The v-key's read-only vendor-HID path does not qualify |
| 2. per-device | The above (per-device branching of ordinary keys becomes necessary) + "misfires on the built-in keyboard" are concretely reported by multiple users. Note: the v-key's IOHIDManager VID/PID match only reads its own vendor page and does not count as this per-device routing |
| 3. dead-key origination | A concrete use case appears where chord must emit F21-F24 or similar |
| 4. BLE | (Impossible in principle. Nothing to reconsider) |
| 5. JSON config | The TOML parser hits a fatal edge case and switching to JSON becomes smaller than fixing TOML |
| 6. HUD notification | A requirement `action-shell` delegation cannot possibly satisfy (e.g. zero-latency visuals synchronous with the tap callback) is concretely reported by multiple users |

All of them presuppose **a concrete "something worth sacrificing the USP
for"**. An abstract "would be convenient" does not reopen them.

---

## References

- [skhd survey notes](https://github.com/akira-toriyama/chord/issues) — for
  the feature comparison, see CLAUDE.md's References section
- [Karabiner-Elements complex_modifications](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/)
- [ZMK behaviors](https://zmk.dev/docs/keymaps/behaviors)

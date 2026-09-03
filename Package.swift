// swift-tools-version:6.0
//
// chord — global keyboard + mouse hotkey daemon for macOS.
//
// Architecture is hexagonal (Ports & Adapters), mirroring wand /
// facet's three-layer split. See docs/architecture.md for the
// diagram.
//
//   ChordCore           pure logic: binding model, TOML config,
//                       event-to-binding matching, key-name lookup
//                       (incl. F13–F24). No AppKit, no CGEvent.
//
//   ChordAdapterMacOS   real-world glue: CGEventTap capture of
//                       keyboard + mouse, NSWorkspace frontmost
//                       tracking, accessibility + Input Monitoring
//                       prompts, opt-in vendor-HID v-key read
//                       (VKeyHIDSource via IOHIDManager — usage page
//                       0xFF31, gated by configDeclaresVKeys()),
//                       action dispatch (CGEvent post, shell exec).
//                       The ONLY place CGEvent / AppKit / IOKit
//                       types appear.
//
//   ChordAdapterTest    synthetic EventSource for integration tests
//                       of the matcher pipeline without real HID
//                       hardware.
//
//   ChordApp            executable: @main, CLI argv, Controller
//                       orchestration, DNC IPC for --reload /
//                       --quit.
//
// Tests live under Tests/<Module>Tests. GUI is deliberately absent
// — the app is config.toml-driven (no settings window).

import PackageDescription

let package = Package(
    name: "chord",
    // macOS-26 floor, inherited from sill. sill v2.0.0 raised its own floor to
    // 26 for the SwiftUI migration, so any consumer that steps past sill 1.x
    // adopts it too — this is that step (family policy t-tbar D2 / t-fs7p).
    // Spelled as a string because `.v26` does not exist in this toolchain's
    // PackageDescription.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "chord", targets: ["ChordApp"]),
        .library(name: "ChordCore", targets: ["ChordCore"]),
    ],
    dependencies: [
        // swift-toml-edit — the family's ONE TOML implementation (Sill-1).
        // chord's 434-line hand-rolled parser was the SUPERSET reference the
        // shared parser was modelled on; in atelier Phase 1.6 it folded into
        // sill's `Toml`, and from sill 0.11.0 that module moved out into its
        // own repo (swift-toml-edit). ChordCore takes ONLY `Toml` (zero
        // AppKit, zero theming) via its NESTED, strict skin — since 2.3.1
        // through `parseWithSpans` (the DOM-derived tiler, t-0030/chord#159),
        // whose per-entry line+column spans feed `(config.toml:N:C)`
        // warnings. The module name is unchanged, so chord's `import Toml`
        // survives.
        //
        // Floor 3.0.0, COUPLED to the sill floor below: sill >= 8.1.0 itself
        // requires toml-edit 3.x, so bumping either alone fails to resolve
        // ("root depends on 'swift-toml-edit' 2.0.0..<3.0.0") — move the two
        // together. Dependabot ignores akira-toriyama/*, so nothing else
        // warns about the pairing.
        //
        // v3.0.0 retired the line-based strict scanner: `Toml.parse` now
        // delegates to `parseWithSpans`, so it throws on spellings the old
        // scanner tolerated (triple-quoted values, a control char in a
        // comment, a `[]` header, an invalid bare key, a raw CRLF inside a
        // single-line string) and parses CRLF documents correctly. chord
        // was already on `parseWithSpans` in Sources/, so this is a no-op
        // for the daemon; the committed config.toml parses under v3.
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMajor(from: "3.0.0")),
        // sill — the shared swift-app-family library (atelier). chord is NOT
        // a theme consumer (no Palette / Effects / PaletteKit); it takes only
        // `CLIKit`, the family's shared pure argv tokenizer (Phase 3 M4),
        // which ChordApp consumes to drive the yabai-style `chord <domain>
        // --<verb>` grammar (unknown-flag loud reject + did-you-mean +
        // `-h`/`-V` carve-out). chord has one value-taking flag
        // (`query --recent-fires --limit N`), so it DOES exercise CLIKit's
        // `.value` arity + the D0 verbatim-value path (a `-`-leading arg
        // after `--limit` is a value, not a flag).
        //
        // Floor 8.8.4, COUPLED to the toml-edit floor above (sill >= 8.1.0
        // requires toml-edit 3.x — the two only resolve together).
        //
        // chord consumes CLIKit and ConfigSchema and NOTHING theme-shaped,
        // which is why crossing sill 2 through 8 costs nothing here: every
        // one of those majors, and the 8.1..8.8 minors, landed in the
        // theming surface (macOS floor, ThemeKitUI reshape, typed theme
        // catalog, ambient SwiftUI widgets, SwiftUI-native Themed*Views,
        // ThemedListStyle's capability gating, widget look). No API was
        // removed from either module chord takes.
        // Measured, not assumed — `swift build` is clean with zero source
        // changes and `chord config --emit-schema` is byte-identical to the
        // committed schema, because chord's schema enumerates no theme names.
        // Package.resolved locks the exact commit.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "8.8.4")),
    ],
    targets: [
        .target(
            name: "ChordCore",
            dependencies: [
                .product(name: "Toml", package: "swift-toml-edit"),
                // ConfigSchema: the family's shared decode-free schema
                // descriptor + Draft-07 emitter (atelier #138 S1, sill 1.25.0).
                // ChordConfigSchema is the chord-LOCAL descriptor DATA; the
                // type vocabulary (SchemaField / ObjectShape / SchemaSection /
                // …) and the JSON-Schema lowering live here so facet / wand /
                // perch share one emitter. chord drives it as the pilot.
                .product(name: "ConfigSchema", package: "sill"),
            ]),
        .target(name: "ChordAdapterMacOS", dependencies: ["ChordCore"]),
        .target(name: "ChordAdapterTest", dependencies: ["ChordCore"]),
        .executableTarget(
            name: "ChordApp",
            dependencies: [
                "ChordCore",
                "ChordAdapterMacOS",
                // CLIKit: the family's shared pure argv tokenizer (atelier
                // Phase 3). Drives ChordApp's yabai-style domain-verb CLI —
                // loud unknown-flag rejection with a nearest-match hint and
                // the `-h`/`-V` carve-out — while chord keeps its own verb
                // vocabulary + one-verb-per-domain + modifier-applicability
                // policy (the D4 line: mechanism in sill, policy in the app).
                .product(name: "CLIKit", package: "sill"),
            ]),
        .testTarget(name: "ChordCoreTests", dependencies: ["ChordCore"]),
        .testTarget(
            name: "ChordIntegrationTests",
            // ChordApp is included so CLIDispatchTests can
            // `@testable import ChordApp` and exercise the
            // SubcommandOutcome / dispatchSubcommand surface
            // without spawning a child process. The `@main enum
            // ChordApp` shape was specifically chosen to keep
            // @testable import working (Main.swift docstring).
            dependencies: ["ChordCore", "ChordAdapterTest", "ChordApp"]),
    ]
)

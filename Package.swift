// swift-tools-version:6.0
//
// chord — global keyboard + mouse hotkey daemon for macOS.
//
// Architecture is hexagonal (Ports & Adapters), mirroring stroke /
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
    platforms: [.macOS(.v13)],
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
        // AppKit, zero theming) via its NESTED, strict `parse` skin. The
        // module name is unchanged, so chord's `import Toml` survives.
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMajor(from: "2.0.0")),
        // sill — the shared swift-app-family library (atelier). chord is NOT
        // a theme consumer (no Palette / Effects / PaletteKit); it takes only
        // `CLIKit`, the family's shared pure argv tokenizer (Phase 3 M4),
        // which ChordApp consumes to drive the yabai-style `chord <domain>
        // --<verb>` grammar (unknown-flag loud reject + did-you-mean +
        // `-h`/`-V` carve-out). chord has one value-taking flag
        // (`query --recent-fires --limit N`), so it DOES exercise CLIKit's
        // `.value` arity + the D0 verbatim-value path (a `-`-leading arg
        // after `--limit` is a value, not a flag). Floor bumped to 0.11.0 (the release that removed
        // sill's in-tree `Toml`). Package.resolved locks the exact commit.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "1.27.0")),
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

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
//                       keyboard + mouse, accessibility prompt,
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
        // sill — the shared swift-app-family library (atelier). chord is
        // NOT a theme consumer (its own separate lineage; no Palette /
        // Effects / PaletteKit), but in atelier Phase 1.6 chord's 434-line
        // hand-rolled TOML parser — the SUPERSET reference the shared
        // parser was modelled on — folds into sill's pure, Foundation-only
        // `Toml` module. ChordCore takes ONLY `Toml` (zero AppKit, zero
        // theming) and uses its NESTED, strict `parse` skin. Pinned to the
        // next-minor range like the family apps; Package.resolved locks the
        // exact commit.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "0.8.0")),
    ],
    targets: [
        .target(
            name: "ChordCore",
            dependencies: [.product(name: "Toml", package: "sill")]),
        .target(name: "ChordAdapterMacOS", dependencies: ["ChordCore"]),
        .target(name: "ChordAdapterTest", dependencies: ["ChordCore"]),
        .executableTarget(
            name: "ChordApp",
            dependencies: [
                "ChordCore",
                "ChordAdapterMacOS",
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

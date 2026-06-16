import Foundation

/// Single source of truth for the chord version string.
///
/// Bumped at release time alongside `Info.plist` /
/// `Info.plist.dev` (the macOS bundle versions). `scripts/check-version-sync.sh`
/// runs in CI to assert all three stay aligned — drift between the
/// CLI's `--version` output and the bundled app's `CFBundleShortVersionString`
/// has happened before and is hard to spot in review.
///
/// Consumers:
///   • `chord --version` (`Sources/ChordApp/Main.swift`)
///   • any future `config --show --json` output that embeds the
///     daemon version
///   • Info.plist / Info.plist.dev are NOT consumers — they're parallel
///     declarations and their drift is checked, not derived
public enum ChordVersion {
    public static let current = "0.9.1"
}

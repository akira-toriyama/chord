import Foundation

/// Single source of truth for the chord version string.
///
/// Bumped at release time alongside `Info.plist` (the macOS bundle
/// version). `scripts/check-version-sync.sh` runs in CI to assert the
/// two stay aligned — drift between the CLI's `--version` output and
/// the bundled app's `CFBundleShortVersionString` has happened before
/// and is hard to spot in review. The dev bundle has no separate
/// plist: `package.sh --dev` DERIVES its version from `Info.plist`
/// (appending `-dev`), so only `Info.plist` needs guarding.
///
/// Consumers:
///   • `chord --version` (`Sources/ChordApp/Main.swift`)
///   • any future `config --show --json` output that embeds the
///     daemon version
///   • Info.plist is NOT a consumer — it's a parallel declaration
///     whose drift against this constant is checked, not derived
public enum ChordVersion {
    public static let current = "0.10.0"
}

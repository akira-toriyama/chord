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
///
/// **The guard only compares these two against EACH OTHER**, so both
/// standing still is invisible to it — and that is exactly what
/// happened: this constant said `0.10.0` through the v0.11.0, v1.0.0
/// and v2.0.0 releases (measured against the tags on 2026-08-13),
/// because glyph's rolling draft cuts the tag without touching the
/// source. `chord --version` under-reported by two majors. When you
/// publish a release, bump this and `Info.plist` in the same change.
public enum ChordVersion {
    /// The version the next release will carry — glyph's rolling draft
    /// is the authority for what that is (`gh release list`).
    public static let current = "3.0.0"
}

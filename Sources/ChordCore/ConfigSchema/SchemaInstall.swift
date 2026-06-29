// SchemaInstall.swift — write the config.toml JSON Schema next to the user's
// config so a `#:schema ./config.schema.json` directive resolves for taplo.
// Mirrors HaloConfig.installSchema (idempotent, best-effort, non-fatal).

import Foundation

public extension ChordConfigSchema {
    /// Where the schema sidecar lives — next to `~/.config/chord/config.toml`
    /// (honours XDG_CONFIG_HOME via ChordConfig.path), so `#:schema
    /// ./config.schema.json` resolves relative to the user's .toml.
    static var schemaPath: String {
        (ChordConfig.path as NSString).deletingLastPathComponent
            + "/config.schema.json"
    }

    /// Write the schema next to the user config. IDEMPOTENT (writes only when
    /// the content differs) so it never churns the file or trips the config
    /// watcher (which polls config.toml's mtime, not this sibling). Creates
    /// `~/.config/chord/` if absent. Best-effort: a failure is non-fatal
    /// (completion just won't resolve) so the daemon never fails to start over
    /// it. Returns true iff it actually wrote.
    @discardableResult
    static func installSchema() -> Bool {
        let path = schemaPath
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let want = jsonSchema
        if let current = try? String(contentsOfFile: path, encoding: .utf8),
            current == want
        {
            return false
        }
        return (try? want.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}

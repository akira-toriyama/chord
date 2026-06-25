import Foundation

extension JSONEncoder {
    /// chord's canonical wire encoder: sorted keys + pretty-printed +
    /// unescaped slashes. Single source of truth so the two JSON
    /// emitters — [BindingsSchema.encodeJSON] (`config --show --json` /
    /// `config --validate --json`) and [QuerySchema.encode] (the
    /// `chord query` socket replies) — can't drift apart. The
    /// JSON-is-the-contract rule (chord's CLAUDE.md) means any change to
    /// this formatting is a wire-format change; keep it in one place so
    /// it can't change in one emitter and not the other.
    ///
    /// Error handling is intentionally NOT folded in: each call site
    /// keeps its own policy (`config` throws; the query server falls
    /// back to `{}`), because the failure modes differ.
    static func chordWire() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        return encoder
    }
}

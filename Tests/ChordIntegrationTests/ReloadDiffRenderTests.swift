import Testing
@testable import ChordApp
@testable import ChordCore

/// Covers the `daemon --reload --dry-run` RENDERER (ReloadDiffPrinter).
/// Every config dimension `BindingsSchema.Diff` tracks must actually
/// appear in the printed text — the C2 bugs were dimensions the diff
/// detected but the renderer dropped (a misleading empty / reasonless
/// diff). The renderers return strings, so these are pure data-in /
/// data-out assertions (no stdout capture).
@Suite struct ReloadDiffRenderTests {

    private func doc(_ s: String) throws -> BindingsSchema.Document {
        BindingsSchema.makeDocument(from: try Config.parse(s))
    }

    private func render(old: String, new: String) throws -> String {
        let d = BindingsSchema.diff(old: try doc(old), new: try doc(new))
        return ChordApp.renderReloadDiff(d, snapshotPresent: true)
    }

    // MARK: - cli#1: [input-aliases] bucket

    @Test func inputAliasesOnlyEditRendersNonEmpty() throws {
        // The headline bug: an [input-aliases]-only edit flipped isClean
        // to false but printed nothing → "all-zero empty diff" lie.
        let out = try render(
            old: """
                [input-aliases]
                ULTRA = "rctrl + ralt"
                """,
            new: """
                [input-aliases]
                ULTRA = "rctrl + ralt + rshift"
                """)
        #expect(
            !out.contains("no changes"),
            "input-aliases-only edit rendered as clean")
        #expect(
            out.contains("input-aliases:"),
            "missing input-aliases bucket header")
        #expect(out.contains("~ $ULTRA"), "missing aliased name")
        #expect(out.contains("rctrl + ralt + rshift"), "missing new body")
    }

    @Test func inputAliasesAddAndRemoveRender() throws {
        let out = try render(
            old: """
                [input-aliases]
                GONE = "ralt"
                """,
            new: """
                [input-aliases]
                FRESH = "rshift"
                """)
        #expect(out.contains("+ $FRESH → rshift"), "\(out)")
        #expect(out.contains("- $GONE → ralt"), "\(out)")
    }

    // MARK: - cli#2: describe() surfaces set/toggle-variable name(=value)

    @Test func describeSetVariableShowsNameAndValue() throws {
        let action = try #require(
            try doc(
                """
                [[bindings]]
                name = "leader"
                input = "cmd - j"
                action-set-var = "wm"
                """
            ).bindings.first
        ).action
        #expect(ChordApp.describe(action) == "set-variable wm=1")
    }

    @Test func describeToggleVariableShowsName() throws {
        let action = try #require(
            try doc(
                """
                [[bindings]]
                name = "t"
                input = "cmd - k"
                action-toggle-var = "wm"
                """
            ).bindings.first
        ).action
        #expect(ChordApp.describe(action) == "toggle-variable wm")
    }

    // MARK: - cli#3: changed binding shows WHAT changed

    @Test func conditionChangeIsRendered() throws {
        let base = """
            [[bindings]]
            name = "g"
            input = "cmd - z"
            action-noop = true
            when-var = "a"
            """
        let out = try render(
            old: base + "\nwhen-var-value = 1",
            new: base + "\nwhen-var-value = 2")
        #expect(out.contains("when:"), "\(out)")
        #expect(out.contains("a==1 → a==2"), "\(out)")
    }

    @Test func holdWhileChangeIsRendered() throws {
        let base = """
            [[bindings]]
            name = "h"
            input = "cmd - h"
            action-set-var = "wm"
            """
        let out = try render(
            old: base + "\nhold-while = \"cmd\"",
            new: base + "\nhold-while = \"cmd + opt\"")
        #expect(out.contains("hold-while: cmd → cmd + opt"), "\(out)")
    }

    @Test func onUpChangeIsRendered() throws {
        let base = """
            [[bindings]]
            name = "u"
            input = "cmd - u"
            action-shell = "echo down"
            """
        let out = try render(
            old: base + "\naction-shell-on-up = \"echo up1\"",
            new: base + "\naction-shell-on-up = \"echo up2\"")
        #expect(out.contains("on-up:"), "\(out)")
        #expect(out.contains("shell echo up1 → shell echo up2"), "\(out)")
    }

    @Test func passthroughChangeIsRendered() throws {
        // End-to-end: detection (semanticallyEqual) + rendering together.
        let base = """
            [[bindings]]
            name = "p"
            input = "cmd - p"
            action-shell = "echo hi"
            """
        let out = try render(old: base, new: base + "\npassthrough = true")
        #expect(
            !out.contains("no changes"),
            "passthrough-only edit rendered as clean")
        #expect(out.contains("passthrough: false → true"), "\(out)")
    }

    // MARK: - regression: a truly identical config still says "no changes"

    @Test func identicalConfigSaysNoChanges() throws {
        let src = """
            [[bindings]]
            name = "x"
            input = "cmd - x"
            action-shell = "echo hi"
            """
        let out = try render(old: src, new: src)
        #expect(out.contains("no changes"), "\(out)")
    }
}

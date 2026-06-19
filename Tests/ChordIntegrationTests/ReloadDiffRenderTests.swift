import XCTest
@testable import ChordApp
@testable import ChordCore

/// Covers the `daemon --reload --dry-run` RENDERER (ReloadDiffPrinter).
/// Every config dimension `BindingsSchema.Diff` tracks must actually
/// appear in the printed text — the C2 bugs were dimensions the diff
/// detected but the renderer dropped (a misleading empty / reasonless
/// diff). The renderers return strings, so these are pure data-in /
/// data-out assertions (no stdout capture).
final class ReloadDiffRenderTests: XCTestCase {

    private func doc(_ s: String) throws -> BindingsSchema.Document {
        BindingsSchema.makeDocument(from: try Config.parse(s))
    }

    private func render(old: String, new: String) throws -> String {
        let d = BindingsSchema.diff(old: try doc(old), new: try doc(new))
        return ChordApp.renderReloadDiff(d, snapshotPresent: true)
    }

    // MARK: - cli#1: [input-aliases] bucket

    func testInputAliasesOnlyEditRendersNonEmpty() throws {
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
        XCTAssertFalse(out.contains("no changes"),
                       "input-aliases-only edit rendered as clean")
        XCTAssertTrue(out.contains("input-aliases:"),
                      "missing input-aliases bucket header")
        XCTAssertTrue(out.contains("~ $ULTRA"), "missing aliased name")
        XCTAssertTrue(out.contains("rctrl + ralt + rshift"), "missing new body")
    }

    func testInputAliasesAddAndRemoveRender() throws {
        let out = try render(
            old: """
            [input-aliases]
            GONE = "ralt"
            """,
            new: """
            [input-aliases]
            FRESH = "rshift"
            """)
        XCTAssertTrue(out.contains("+ $FRESH → rshift"), out)
        XCTAssertTrue(out.contains("- $GONE → ralt"), out)
    }

    // MARK: - cli#2: describe() surfaces set/toggle-variable name(=value)

    func testDescribeSetVariableShowsNameAndValue() throws {
        let action = try XCTUnwrap(try doc("""
        [[bindings]]
        name = "leader"
        input = "cmd - j"
        action-set-var = "wm"
        """).bindings.first).action
        XCTAssertEqual(ChordApp.describe(action), "set-variable wm=1")
    }

    func testDescribeToggleVariableShowsName() throws {
        let action = try XCTUnwrap(try doc("""
        [[bindings]]
        name = "t"
        input = "cmd - k"
        action-toggle-var = "wm"
        """).bindings.first).action
        XCTAssertEqual(ChordApp.describe(action), "toggle-variable wm")
    }

    // MARK: - cli#3: changed binding shows WHAT changed

    func testConditionChangeIsRendered() throws {
        let base = """
        [[bindings]]
        name = "g"
        input = "cmd - z"
        action-noop = true
        when-var = "a"
        """
        let out = try render(old: base + "\nwhen-var-value = 1",
                             new: base + "\nwhen-var-value = 2")
        XCTAssertTrue(out.contains("when:"), out)
        XCTAssertTrue(out.contains("a==1 → a==2"), out)
    }

    func testHoldWhileChangeIsRendered() throws {
        let base = """
        [[bindings]]
        name = "h"
        input = "cmd - h"
        action-set-var = "wm"
        """
        let out = try render(old: base + "\nhold-while = \"cmd\"",
                             new: base + "\nhold-while = \"cmd + opt\"")
        XCTAssertTrue(out.contains("hold-while: cmd → cmd + opt"), out)
    }

    func testOnUpChangeIsRendered() throws {
        let base = """
        [[bindings]]
        name = "u"
        input = "cmd - u"
        action-shell = "echo down"
        """
        let out = try render(old: base + "\naction-shell-on-up = \"echo up1\"",
                             new: base + "\naction-shell-on-up = \"echo up2\"")
        XCTAssertTrue(out.contains("on-up:"), out)
        XCTAssertTrue(out.contains("shell echo up1 → shell echo up2"), out)
    }

    func testPassthroughChangeIsRendered() throws {
        // End-to-end: detection (semanticallyEqual) + rendering together.
        let base = """
        [[bindings]]
        name = "p"
        input = "cmd - p"
        action-shell = "echo hi"
        """
        let out = try render(old: base, new: base + "\npassthrough = true")
        XCTAssertFalse(out.contains("no changes"),
                       "passthrough-only edit rendered as clean")
        XCTAssertTrue(out.contains("passthrough: false → true"), out)
    }

    // MARK: - regression: a truly identical config still says "no changes"

    func testIdenticalConfigSaysNoChanges() throws {
        let src = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-shell = "echo hi"
        """
        let out = try render(old: src, new: src)
        XCTAssertTrue(out.contains("no changes"), out)
    }
}

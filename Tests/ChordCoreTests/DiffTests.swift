import XCTest
@testable import ChordCore

/// Coverage for the `daemon --reload --dry-run` diff algorithm. Bindings
/// match by name; semantic equality ignores line numbers /
/// document order.
final class DiffTests: XCTestCase {

    private func doc(_ source: String) throws -> BindingsSchema.Document {
        let res = try Config.parse(source)
        return BindingsSchema.makeDocument(from: res)
    }

    func testNoSnapshotEverythingAdded() throws {
        let new = try doc("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let d = BindingsSchema.diff(old: nil, new: new)
        XCTAssertEqual(d.addedBindings.count, 1)
        XCTAssertEqual(d.addedBindings[0].name, "x")
        XCTAssertTrue(d.removedBindings.isEmpty)
        XCTAssertTrue(d.changedBindings.isEmpty)
    }

    func testIdenticalDocsAreClean() throws {
        let src = """
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """
        let a = try doc(src)
        let b = try doc(src)
        let d = BindingsSchema.diff(old: a, new: b)
        XCTAssertTrue(d.isClean)
        XCTAssertEqual(d.unchangedBindingCount, 1)
    }

    func testNameChangeIsAddedPlusRemoved() throws {
        let oldDoc = try doc("""
        [[bindings]]
        name = "old name"
        input = "f13"
        action-noop = true
        """)
        let newDoc = try doc("""
        [[bindings]]
        name = "new name"
        input = "f13"
        action-noop = true
        """)
        let d = BindingsSchema.diff(old: oldDoc, new: newDoc)
        XCTAssertEqual(d.addedBindings.map(\.name), ["new name"])
        XCTAssertEqual(d.removedBindings.map(\.name), ["old name"])
        XCTAssertTrue(d.changedBindings.isEmpty)
    }

    func testSameNameDifferentInputIsChanged() throws {
        let oldDoc = try doc("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let newDoc = try doc("""
        [[bindings]]
        name = "x"
        input = "f14"
        action-noop = true
        """)
        let d = BindingsSchema.diff(old: oldDoc, new: newDoc)
        XCTAssertTrue(d.addedBindings.isEmpty)
        XCTAssertTrue(d.removedBindings.isEmpty)
        XCTAssertEqual(d.changedBindings.count, 1)
        XCTAssertEqual(d.changedBindings[0].old.input.raw, "f13")
        XCTAssertEqual(d.changedBindings[0].new.input.raw, "f14")
    }

    func testLineShiftIsNotChange() throws {
        // Inserting a different binding above shouldn't surface the
        // shifted binding as "changed". Its source_line moves but
        // its name + input + action are stable.
        let oldDoc = try doc("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let newDoc = try doc("""
        [[bindings]]
        name = "newcomer"
        input = "f24"
        action-noop = true

        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let d = BindingsSchema.diff(old: oldDoc, new: newDoc)
        XCTAssertEqual(d.addedBindings.map(\.name), ["newcomer"])
        XCTAssertTrue(d.changedBindings.isEmpty)
        XCTAssertEqual(d.unchangedBindingCount, 1)
    }

    func testFallbacksDiffSeparately() throws {
        let oldDoc = try doc("""
        [[bindings]]
        name = "b"
        input = "f13"
        action-noop = true

        [[fallbacks]]
        name = "ultra fallback"
        input = "rctrl + ralt + rshift - *"
        action-shell = "afplay /System/Library/Sounds/Pop.aiff"
        """)
        let newDoc = try doc("""
        [[bindings]]
        name = "b"
        input = "f13"
        action-noop = true

        [[fallbacks]]
        name = "ultra fallback"
        input = "rctrl + ralt + rshift - *"
        action-shell = "afplay /System/Library/Sounds/Glass.aiff"
        """)
        let d = BindingsSchema.diff(old: oldDoc, new: newDoc)
        XCTAssertEqual(d.unchangedBindingCount, 1)
        XCTAssertEqual(d.changedFallbacks.count, 1)
        XCTAssertTrue(d.addedFallbacks.isEmpty)
    }

    func testAliasDiff() throws {
        let oldDoc = try doc("""
        [action-aliases]
        keep = "echo keep"
        change = "echo old"
        gone  = "echo bye"
        """)
        let newDoc = try doc("""
        [action-aliases]
        keep = "echo keep"
        change = "echo new"
        fresh = "echo hi"
        """)
        let d = BindingsSchema.diff(old: oldDoc, new: newDoc)
        XCTAssertEqual(d.actionAliasesAdded, ["fresh": "echo hi"])
        XCTAssertEqual(d.actionAliasesRemoved, ["gone": "echo bye"])
        XCTAssertEqual(d.actionAliasesChanged.count, 1)
        XCTAssertEqual(d.actionAliasesChanged[0].name, "change")
        XCTAssertEqual(d.actionAliasesChanged[0].oldBody, "echo old")
        XCTAssertEqual(d.actionAliasesChanged[0].newBody, "echo new")
    }

    // MARK: - younger fields (chord 0.9.0+) must register as changes
    //
    // Regression for C2/cli#4: semanticallyEqual ignored passthrough /
    // repeatStrategy / inputSource, so an edit touching ONLY one of them
    // reported "no change" (the dry-run lied). Each must now surface as a
    // changed binding.

    func testPassthroughOnlyEditIsChanged() throws {
        let base = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-shell = "echo hi"
        """
        let d = BindingsSchema.diff(old: try doc(base),
                                    new: try doc(base + "\npassthrough = true"))
        XCTAssertEqual(d.changedBindings.count, 1,
                       "passthrough-only edit must surface as changed")
        XCTAssertEqual(d.unchangedBindingCount, 0)
    }

    func testRepeatOnlyEditIsChanged() throws {
        let base = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-shell = "echo hi"
        """
        let d = BindingsSchema.diff(old: try doc(base),
                                    new: try doc(base + "\nrepeat = \"ignore\""))
        XCTAssertEqual(d.changedBindings.count, 1,
                       "repeat-only edit must surface as changed")
    }

    func testInputSourceOnlyEditIsChanged() throws {
        let base = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-noop = true
        """
        let d = BindingsSchema.diff(
            old: try doc(base),
            new: try doc(base + "\ninput-source = [\"com.apple.keylayout.US\"]"))
        XCTAssertEqual(d.changedBindings.count, 1,
                       "input-source-only edit must surface as changed")
    }

    func testConditionOnlyEditIsChanged() throws {
        let oldDoc = try doc("""
        [[bindings]]
        name = "g"
        input = "cmd - z"
        when-var = "a"
        when-var-value = 1
        action-noop = true
        """)
        let newDoc = try doc("""
        [[bindings]]
        name = "g"
        input = "cmd - z"
        when-var = "a"
        when-var-value = 2
        action-noop = true
        """)
        let d = BindingsSchema.diff(old: oldDoc, new: newDoc)
        XCTAssertEqual(d.changedBindings.count, 1,
                       "when-var value change must surface as changed")
    }
}

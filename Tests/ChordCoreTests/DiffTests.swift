import Testing
@testable import ChordCore

/// Coverage for the `daemon --reload --dry-run` diff algorithm. Bindings
/// match by name; semantic equality ignores line numbers /
/// document order.
@Suite struct DiffTests {

    private func doc(_ source: String) throws -> BindingsSchema.Document {
        let res = try Config.parse(source)
        return BindingsSchema.makeDocument(from: res)
    }

    @Test func noSnapshotEverythingAdded() throws {
        let new = try doc("""
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """)
        let d = BindingsSchema.diff(old: nil, new: new)
        #expect(d.addedBindings.count == 1)
        #expect(d.addedBindings[0].name == "x")
        #expect(d.removedBindings.isEmpty)
        #expect(d.changedBindings.isEmpty)
    }

    @Test func identicalDocsAreClean() throws {
        let src = """
        [[bindings]]
        name = "x"
        input = "f13"
        action-noop = true
        """
        let a = try doc(src)
        let b = try doc(src)
        let d = BindingsSchema.diff(old: a, new: b)
        #expect(d.isClean)
        #expect(d.unchangedBindingCount == 1)
    }

    @Test func nameChangeIsAddedPlusRemoved() throws {
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
        #expect(d.addedBindings.map(\.name) == ["new name"])
        #expect(d.removedBindings.map(\.name) == ["old name"])
        #expect(d.changedBindings.isEmpty)
    }

    @Test func sameNameDifferentInputIsChanged() throws {
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
        #expect(d.addedBindings.isEmpty)
        #expect(d.removedBindings.isEmpty)
        #expect(d.changedBindings.count == 1)
        #expect(d.changedBindings[0].old.input.raw == "f13")
        #expect(d.changedBindings[0].new.input.raw == "f14")
    }

    @Test func lineShiftIsNotChange() throws {
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
        #expect(d.addedBindings.map(\.name) == ["newcomer"])
        #expect(d.changedBindings.isEmpty)
        #expect(d.unchangedBindingCount == 1)
    }

    @Test func fallbacksDiffSeparately() throws {
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
        #expect(d.unchangedBindingCount == 1)
        #expect(d.changedFallbacks.count == 1)
        #expect(d.addedFallbacks.isEmpty)
    }

    @Test func aliasDiff() throws {
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
        #expect(d.actionAliasesAdded == ["fresh": "echo hi"])
        #expect(d.actionAliasesRemoved == ["gone": "echo bye"])
        #expect(d.actionAliasesChanged.count == 1)
        #expect(d.actionAliasesChanged[0].name == "change")
        #expect(d.actionAliasesChanged[0].oldBody == "echo old")
        #expect(d.actionAliasesChanged[0].newBody == "echo new")
    }

    // MARK: - younger fields (chord 0.9.0+) must register as changes
    //
    // Regression for C2/cli#4: semanticallyEqual ignored passthrough /
    // repeatStrategy / inputSource, so an edit touching ONLY one of them
    // reported "no change" (the dry-run lied). Each must now surface as a
    // changed binding.

    @Test func passthroughOnlyEditIsChanged() throws {
        let base = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-shell = "echo hi"
        """
        let d = BindingsSchema.diff(old: try doc(base),
                                    new: try doc(base + "\npassthrough = true"))
        #expect(d.changedBindings.count == 1,
                "passthrough-only edit must surface as changed")
        #expect(d.unchangedBindingCount == 0)
    }

    @Test func repeatOnlyEditIsChanged() throws {
        let base = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-shell = "echo hi"
        """
        let d = BindingsSchema.diff(old: try doc(base),
                                    new: try doc(base + "\nrepeat = \"ignore\""))
        #expect(d.changedBindings.count == 1,
                "repeat-only edit must surface as changed")
    }

    @Test func inputSourceOnlyEditIsChanged() throws {
        let base = """
        [[bindings]]
        name = "x"
        input = "cmd - x"
        action-noop = true
        """
        let d = BindingsSchema.diff(
            old: try doc(base),
            new: try doc(base + "\ninput-source = [\"com.apple.keylayout.US\"]"))
        #expect(d.changedBindings.count == 1,
                "input-source-only edit must surface as changed")
    }

    @Test func conditionOnlyEditIsChanged() throws {
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
        #expect(d.changedBindings.count == 1,
                "when-var value change must surface as changed")
    }
}

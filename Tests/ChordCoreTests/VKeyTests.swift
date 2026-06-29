import Testing
@testable import ChordCore

/// Vendor-HID "v-key" path: `[v-key-aliases] NAME = <id>` + a binding that
/// selects one via a bare `input = "<name>"`. vkeys are ordinary bindings
/// carrying a `.vkey(id)` trigger, so apps / when-var / on-up all work and
/// they flow through the same Matcher as keyboard bindings.
@Suite struct VKeyTests {
    /// A `[v-key-aliases]` entry + a bare-name `input` becomes a
    /// `.vkey(id)` trigger with no modifiers.
    @Test func vKeyAliasResolvesToTrigger() throws {
        let source = """
            [v-key-aliases]
            TU_LL_C = 0x26

            [[bindings]]
            name = "paste"
            input = "TU_LL_C"
            action-keys = "cmd - v"
            """
        let r = try Config.parse(source)
        #expect(r.droppedBindings == 0)
        #expect(r.config.bindings.count == 1)
        #expect(r.config.bindings[0].trigger == .vkey(0x26))
        #expect(r.config.bindings[0].modifiers == [])
    }

    /// The migration's core case: ONE id, two app-scoped bindings. Both
    /// load; the Matcher routes by frontmost app (this is exactly what the
    /// flat `[[vkey]]` design could NOT express).
    @Test func vKeyAppRouting() throws {
        let source = """
            [v-key-aliases]
            TU_LL_C = 38

            [[bindings]]
            name = "chrome"
            input = "TU_LL_C"
            apps = ["com.google.Chrome"]
            action-keys = "ctrl + shift - tab"

            [[bindings]]
            name = "vscode"
            input = "TU_LL_C"
            apps = ["com.microsoft.VSCode"]
            action-keys = "cmd + shift - ["
            """
        let r = try Config.parse(source)
        #expect(r.droppedBindings == 0)
        #expect(r.config.bindings.count == 2)
        let m = Matcher(bindings: r.config.bindings)
        #expect(
            m.find(
                .init(
                    trigger: .vkey(38), modifiers: [],
                    bundleID: "com.google.Chrome"))?.name == "chrome")
        #expect(
            m.find(
                .init(
                    trigger: .vkey(38), modifiers: [],
                    bundleID: "com.microsoft.VSCode"))?.name == "vscode")
        // An app neither binding scopes to → no match (would beep via the
        // any-vkey fallback if one were declared).
        #expect(
            m.find(
                .init(
                    trigger: .vkey(38), modifiers: [],
                    bundleID: "com.apple.Terminal")) == nil)
    }

    /// The bare `v-key` literal is the any-vkey wildcard — `[[fallbacks]]`
    /// only; the single-sound "undefined vkey" feedback bucket.
    @Test func anyVKeyWildcardFallback() throws {
        let source = """
            [[fallbacks]]
            name = "undefined vkey beep"
            input = "v-key"
            action-shell = "afplay /x.aiff"
            """
        let r = try Config.parse(source)
        #expect(r.droppedBindings == 0)
        #expect(r.config.fallbacks.count == 1)
        #expect(r.config.fallbacks[0].trigger == .anyVKey)
        let m = Matcher(bindings: [], fallbacks: r.config.fallbacks)
        // Matches any vkey the bindings missed…
        #expect(
            m.find(.init(trigger: .vkey(99), modifiers: [], bundleID: nil))?.name
                == "undefined vkey beep")
        // …but not a keyboard key (that is `*` / .anyKey territory).
        #expect(m.find(.init(trigger: .key(0), modifiers: [], bundleID: nil)) == nil)
    }

    /// `v-key` in a regular `[[bindings]]` is rejected (wildcard is
    /// fallback-only, same contract as `*`).
    @Test func anyVKeyRejectedInBindings() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            input = "v-key"
            action-noop = true
            """)
        #expect(r.config.bindings.count == 0)
        #expect(r.droppedBindings >= 1)
    }

    /// Out-of-range alias id is ignored; a binding that references it then
    /// fails to resolve and drops.
    @Test func aliasOutOfRangeIgnored() throws {
        let r = try Config.parse(
            """
            [v-key-aliases]
            BAD = 999

            [[bindings]]
            input = "BAD"
            action-noop = true
            """)
        #expect(r.config.bindings.count == 0)
        #expect(r.droppedBindings >= 1)
    }

    /// An alias name that shadows a real keycode is rejected — `input = "a"`
    /// then resolves to the literal key `a`, never the alias (ambiguity
    /// guard keeps bare-name resolution sound).
    @Test func aliasShadowingKeycodeIgnored() throws {
        let r = try Config.parse(
            """
            [v-key-aliases]
            a = 5

            [[bindings]]
            input = "a"
            action-noop = true
            """)
        #expect(r.config.bindings.count == 1)
        #expect(r.config.bindings[0].trigger == .key(KeyCodes.code(forName: "a")!))
    }

    /// Hex (`0x1A`) and decimal (`26`) id forms are equivalent. (Alias
    /// names are deliberately NON-keycode — a single-letter name like `H`
    /// would be rejected as keycode-shadowing, see
    /// `aliasShadowingKeycodeIgnored`.)
    @Test func hexAndDecimalIds() throws {
        let r = try Config.parse(
            """
            [v-key-aliases]
            VKHEX = 0x1A
            VKDEC = 26

            [[bindings]]
            input = "VKHEX"
            action-noop = true

            [[bindings]]
            input = "VKDEC"
            action-noop = true
            """)
        #expect(r.config.bindings.count == 2)
        #expect(r.config.bindings[0].trigger == .vkey(0x1A))
        #expect(r.config.bindings[1].trigger == .vkey(26))
    }
}

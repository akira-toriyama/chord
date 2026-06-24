import Testing
@testable import ChordCore

@Suite struct ConfigTests {
    @Test func parsesAllActionShapes() throws {
        let source = """
        [options]
        passthrough-unmatched = true
        exclude-apps = ["com.apple.dt.Xcode"]

        [[bindings]]
        name = "launch terminal"
        input = "f13"
        action-shell = "open -a Terminal"

        [[bindings]]
        name = "screenshot"
        input = "mouse.side1"
        action-keys = "cmd + shift - 4"

        [[bindings]]
        name = "block caps"
        input = "caps_lock"
        action-noop = true
        """
        let r = try Config.parse(source)
        #expect(r.config.bindings.count == 3)
        #expect(r.droppedBindings == 0)
        #expect(r.config.options.excludeApps ==
                       ["com.apple.dt.Xcode"])

        switch r.config.bindings[0].action {
        case .shell(let s): #expect(s == "open -a Terminal")
        default: Issue.record("expected shell action")
        }
        switch r.config.bindings[1].action {
        case .keys(let mods, let code):
            #expect(mods == [.cmd, .shift])
            #expect(code == 0x15)
        default: Issue.record("expected keys action")
        }
        #expect(r.config.bindings[2].action == .noop)
    }

    @Test func badBindingDoesNotBreakOthers() throws {
        let source = """
        [[bindings]]
        name = "bad"
        input = "no-such-key"
        action-shell = "true"

        [[bindings]]
        name = "good"
        input = "f14"
        action-shell = "true"
        """
        let r = try Config.parse(source)
        #expect(r.droppedBindings == 1)
        #expect(r.config.bindings.count == 1)
        #expect(r.config.bindings[0].name == "good")
    }

    @Test func shellPlusKeysCombineOnDown() throws {
        let source = """
        [[bindings]]
        name = "facet then nav"
        input = "ctrl - right"
        action-shell = "facet --view=tree --loading=2000"
        action-keys = "ctrl - right"
        """
        let r = try Config.parse(source)
        #expect(r.droppedBindings == 0)
        #expect(r.config.bindings.count == 1)
        let b = r.config.bindings[0]
        // Shell becomes the primary (it fires first on down)…
        switch b.action {
        case .shell(let s):
            #expect(s == "facet --view=tree --loading=2000")
        default: Issue.record("expected shell primary action")
        }
        // …and the keys land in extraDownActions (posted right after).
        #expect(b.extraDownActions.count == 1)
        switch b.extraDownActions.first {
        case .keys(let mods, let code):
            #expect(mods == [.ctrl])
            #expect(code == 0x7C)
        default: Issue.record("expected a chained keys action")
        }
    }

    @Test func shellPlusBadKeysDropsBinding() throws {
        let source = """
        [[bindings]]
        name = "broken combo"
        input = "ctrl - right"
        action-shell = "true"
        action-keys = "no-such-key"
        """
        let r = try Config.parse(source)
        #expect(r.droppedBindings == 1)
        #expect(r.config.bindings.count == 0)
    }

    @Test func extraActionsSurfaceInWireSchema() throws {
        let source = """
        [[bindings]]
        name = "facet then nav"
        input = "ctrl - right"
        action-shell = "facet --view=tree"
        action-keys = "ctrl - right"
        """
        let r = try Config.parse(source)
        let doc = BindingsSchema.makeDocument(from: r)
        let extra = doc.bindings[0].extraActions
        #expect(extra?.count == 1)
        #expect(extra?.first?.kind == "keys")
        #expect(extra?.first?.key?.keycode == 0x7C)
    }

    // MARK: - silent-drop fixes (analysis report items 2A / 2B)

    /// `[options]` typos used to be silent — the binding parser
    /// only checks the keys it knows about, so a camelCase typo
    /// (`passthroughUnmatched`) or an invented key looked exactly
    /// like "it worked but had no effect". Warn on every unknown
    /// key so `config --validate --strict` catches it in CI.
    @Test func unknownOptionKeyWarns() throws {
        let source = """
        [options]
        passthrough-unmatched = true
        passthroughUnmatched = false
        bogus-option = "what"
        """
        let r = try Config.parse(source)
        #expect(r.config.options.passthroughUnmatched == true,
                       "the kebab-case key still wins")
        let kinds = r.warnings.map(\.kind)
        #expect(kinds.filter { $0 == .unknownOptionKey }.count == 2)
        // The kebab-case key is NOT flagged as unknown.
        #expect(!r.warnings.contains { w in
            w.kind == .unknownOptionKey && w.message.contains("'passthrough-unmatched'")
        })
        // The two known-bad keys ARE flagged.
        #expect(r.warnings.contains { w in
            w.kind == .unknownOptionKey && w.message.contains("'passthroughUnmatched'")
        })
        #expect(r.warnings.contains { w in
            w.kind == .unknownOptionKey && w.message.contains("'bogus-option'")
        })
    }

    // MARK: - #52-bounded: descriptor-driven unknown-key validation

    /// A typo on an OPTIONAL binding key warns (.unknownKey) but the binding
    /// still loads — the unknown key is lenient, like [options].
    @Test func unknownBindingKeyWarns() throws {
        let source = """
        [[bindings]]
        name = "typo"
        input = "cmd - a"
        action-shell = "echo hi"
        passthrouh = true
        """
        let r = try Config.parse(source)
        #expect(r.config.bindings.count == 1, "binding still loads")
        #expect(r.droppedBindings == 0)
        #expect(r.warnings.filter { $0.kind == .unknownKey }.count == 1)
        #expect(r.warnings.contains {
            $0.kind == .unknownKey && $0.message.contains("'passthrouh'")
        })
    }

    /// Unknown keys are caught in every closed shape, including the nested
    /// per-app / sequence.bindings rows, each labelled with its section.
    @Test func unknownKeyAcrossNestedShapes() throws {
        let source = """
        [[bindings]]
        input = "cmd - a"
        action-noop = true
          [[bindings.per-app]]
          bundle-id = "com.apple.Terminal"
          action-keys = "cmd - v"
          appz = ["x"]

        [[fallbacks]]
        input = "*"
        action-noop = true
        nope = 1

        [[sequence]]
        prefix = "cmd - g"
        timeout-ms = 800
          [[sequence.bindings]]
          input = "h"
          action-noop = true
          wat = 2

        [[remap]]
        modifiers = "cmd"
        map = { h = "left" }
        huh = 3
        """
        let r = try Config.parse(source)
        let unknown = r.warnings.filter { $0.kind == .unknownKey }
        #expect(unknown.count == 4)
        #expect(unknown.contains { $0.message.contains("[[bindings.per-app]]") && $0.message.contains("'appz'") })
        #expect(unknown.contains { $0.message.contains("[[fallbacks]]") && $0.message.contains("'nope'") })
        #expect(unknown.contains { $0.message.contains("[[sequence.bindings]]") && $0.message.contains("'wat'") })
        #expect(unknown.contains { $0.message.contains("[[remap]]") && $0.message.contains("'huh'") })
    }

    /// A typo'd top-level SECTION header (`[[bindigs]]`, `[optoins]`) used
    /// to parse as a brand-new section that nothing reads — the rows it
    /// "contained" silently vanished and `--validate --strict` passed, even
    /// though the editor JSON schema flags the same typo. Warn (.unknownKey)
    /// so the CLI is at least as strict as the schema.
    @Test func unknownTopLevelSectionWarns() throws {
        let source = """
        [[bindigs]]
        name = "oops"
        input = "cmd - a"
        action-noop = true

        [optoins]
        passthrough-unmatched = false
        """
        let r = try Config.parse(source)
        // The mistyped binding section did NOT load any binding.
        #expect(r.config.bindings.count == 0)
        let sectionWarnings = r.warnings.filter {
            $0.kind == .unknownKey && $0.message.contains("top-level section")
        }
        #expect(sectionWarnings.count == 2)
        #expect(sectionWarnings.contains { $0.message.contains("[bindigs]") })
        #expect(sectionWarnings.contains { $0.message.contains("[optoins]") })
    }

    /// Negative: a correctly-spelled config (every valid section present)
    /// produces NO top-level-section warning — guards against the root
    /// scan mis-flagging a legitimate section name.
    @Test func knownTopLevelSectionsDoNotWarn() throws {
        let source = """
        [options]
        passthrough-unmatched = true
        [action-aliases]
        hi = "echo hi"
        [input-aliases]
        hyper = "cmd + opt + ctrl + shift"
        [v-key-aliases]
        vol = 161
        [[bindings]]
        input = "cmd - a"
        action-noop = true
        [[fallbacks]]
        input = "*"
        action-noop = true
        [[sequence]]
        prefix = "cmd - g"
        timeout-ms = 800
          [[sequence.bindings]]
          input = "h"
          action-noop = true
        [[remap]]
        modifiers = "cmd"
        map = { h = "left" }
        """
        let r = try Config.parse(source)
        #expect(!r.warnings.contains {
            $0.kind == .unknownKey && $0.message.contains("top-level section")
        })
    }

    /// `action-toggle-var-on-up` / `action-hold-var-on-up` are recognised-
    /// to-reject (rejected fields): the parser emits its SPECIFIC rejection,
    /// NOT a misleading "unknown key" — the descriptor's keySet includes them
    /// so the #52 check stays quiet.
    @Test func rejectedOnUpKeysNotReportedAsUnknown() throws {
        let source = """
        [[bindings]]
        name = "toggle-onup"
        input = "cmd - a"
        action-toggle-var = "x"
        action-toggle-var-on-up = "x"
        """
        let r = try Config.parse(source)
        #expect(!r.warnings.contains { $0.kind == .unknownKey },
                       "a recognised-to-reject key must not be flagged as unknown")
        // The binding is dropped via the specific rejection instead.
        #expect(r.config.bindings.count == 0)
    }

    /// The false-positive guard: a binding exercising a broad spread of known
    /// keys (the descriptor's keySet) must produce ZERO .unknownKey warnings.
    /// Catches a descriptor that drops a key the parser actually consumes.
    @Test func knownBindingKeysProduceNoUnknownWarning() throws {
        let source = """
        [[bindings]]
        name = "full"
        input = "cmd - a"
        action-shell = "echo hi"
        action-keys = "cmd - c"
        action-shell-on-up = "echo bye"
        when-vars = { layer = 1 }
        input-source = "com.apple.keylayout.US"
        passthrough = false
        repeat = "ignore"
          [[bindings.per-app]]
          bundle-id = "com.apple.Terminal"
          action-keys = "cmd - v"

        [[bindings]]
        name = "setvar"
        input = "cmd - b"
        action-set-var = "layer"
        action-set-value = 1
        hold-while = "cmd"
        apps = ["com.apple.Safari"]
        """
        let r = try Config.parse(source)
        let unknown = r.warnings.filter { $0.kind == .unknownKey }
        #expect(unknown.isEmpty,
                      "known keys must not be flagged: \(unknown.map { $0.message })")
    }

    /// #52-bounded: the per-app layerable set is DERIVED from perAppShape, so
    /// every action the descriptor lists actually layers — closing a stale-
    /// allowlist bug where action-toggle-var / action-hold-var /
    /// action-mission-control / action-screenshot / action-spotlight were
    /// silently dropped from a per-app override (dropping the whole binding
    /// when the base had no action of its own).
    @Test func perAppLayersDescriptorActions() throws {
        let source = """
        [[bindings]]
        name = "base"
        input = "cmd - a"
          [[bindings.per-app]]
          bundle-id = "com.apple.Terminal"
          action-toggle-var = "termlayer"
        """
        let r = try Config.parse(source)
        #expect(!r.warnings.contains { $0.kind == .unknownKey })
        #expect(r.config.bindings.count == 1, "the per-app binding loads, not dropped")
        guard case .toggleVariable = r.config.bindings.first?.action else {
            Issue.record("per-app action-toggle-var must layer onto the base binding")
            return
        }
    }

    /// Two user-named bindings sharing a name still load (chord
    /// doesn't enforce uniqueness — the order-based first-match-wins
    /// matcher copes), but `config --show --json` consumers and the
    /// `daemon --reload --dry-run` name-keyed diff can't tell them apart.
    /// Surface the ambiguity as a warning so it doesn't silently
    /// degrade the introspection tooling.
    @Test func duplicateBindingNameWarns() throws {
        let source = """
        [[bindings]]
        name = "twin"
        input = "f13"
        action-noop = true

        [[bindings]]
        name = "twin"
        input = "f14"
        action-noop = true
        """
        let r = try Config.parse(source)
        #expect(r.config.bindings.count == 2,
                       "both still load — uniqueness is not enforced")
        let dups = r.warnings.filter { $0.kind == .duplicateBindingName }
        #expect(dups.count == 1)
        #expect(dups.first?.bindingName == "twin")
    }

    /// Synthetic `binding-N` names from makeBinding's index fallback
    /// (rows with no explicit `name`) are exempt — they're unique by
    /// construction, and warning on them would produce false positives.
    @Test func syntheticBindingNamesExemptFromDuplicateCheck() throws {
        let source = """
        [[bindings]]
        input = "f13"
        action-noop = true

        [[bindings]]
        input = "f14"
        action-noop = true

        [[bindings]]
        input = "f15"
        action-noop = true
        """
        let r = try Config.parse(source)
        #expect(r.config.bindings.count == 3)
        #expect(!r.warnings.contains { $0.kind == .duplicateBindingName })
    }
}

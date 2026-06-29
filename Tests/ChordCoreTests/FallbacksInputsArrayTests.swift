import Testing
@testable import ChordCore

/// chord 0.8.0+: `[[fallbacks]]` accepts `inputs = ["a", "b", ...]`
/// to collapse N modset feedback rows into one block. Each element
/// becomes a fully-formed fallback with the original action / apps
/// shared verbatim.
@Suite struct FallbacksInputsArrayTests {

    // MARK: - Basic expansion

    @Test func inputsArrayExpandsToOneFallbackPerEntry() throws {
        let res = try Config.parse(
            """
            [input-aliases]
            ULTRA_LL   = "rctrl + ralt + rshift"
            MIRACLE_LM = "rctrl + rcmd + rshift"

            [[fallbacks]]
            name = "undefined feedback"
            inputs = ["$ULTRA_LL - *", "$MIRACLE_LM - *"]
            action-shell = "afplay undefined.wav"
            """)
        #expect(res.droppedBindings == 0)
        #expect(
            res.config.fallbacks.count == 2,
            "2-entry inputs[] → 2 fallback bindings")
        // Each carries the same action.
        for fb in res.config.fallbacks {
            if case .shell(let body) = fb.action {
                #expect(body == "afplay undefined.wav")
            } else {
                Issue.record("expected shell action, got \(fb.action)")
            }
        }
        // Names disambiguated by the original input string.
        let names = res.config.fallbacks.map(\.name)
        #expect(
            names == [
                "undefined feedback — $ULTRA_LL - *",
                "undefined feedback — $MIRACLE_LM - *"
            ])
        // inputRaw round-trips (used by config --show --json + warnings).
        #expect(res.config.fallbacks[0].inputRaw == "$ULTRA_LL - *")
        #expect(res.config.fallbacks[1].inputRaw == "$MIRACLE_LM - *")
    }

    @Test func inputsArrayPreservesAppsAndActionAlias() throws {
        let res = try Config.parse(
            """
            [action-aliases]
            beep = "afplay beep.wav"

            [[fallbacks]]
            name = "feedback"
            inputs = ["cmd - *", "opt - *"]
            action-shell = "@beep"
            apps = ["com.apple.Terminal"]
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.fallbacks.count == 2)
        for fb in res.config.fallbacks {
            #expect(fb.apps == ["com.apple.Terminal"])
            #expect(
                fb.aliasName == "beep",
                "@alias resolved per expanded row")
            if case .shell(let body) = fb.action {
                #expect(body == "afplay beep.wav")
            } else {
                Issue.record("expected shell, got \(fb.action)")
            }
        }
    }

    @Test func singleInputStillWorks() throws {
        // Regression: classic single `input = "..."` path is unchanged.
        let res = try Config.parse(
            """
            [[fallbacks]]
            name = "lone fallback"
            input = "cmd - *"
            action-shell = "echo lone"
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.fallbacks.count == 1)
        #expect(res.config.fallbacks[0].name == "lone fallback")
        // No " — <input>" suffix when the row used single input.
        #expect(!res.config.fallbacks[0].name.contains(" — "))
    }

    // MARK: - Validation: error paths

    @Test func inputAndInputsAreMutuallyExclusive() throws {
        let res = try Config.parse(
            """
            [[fallbacks]]
            name = "conflict"
            input = "cmd - *"
            inputs = ["opt - *"]
            action-shell = "echo nope"
            """)
        #expect(res.config.fallbacks.count == 0)
        #expect(res.droppedBindings >= 1)
        #expect(
            res.warnings.contains {
                $0.kind == .missingInput && $0.message.contains("mutually exclusive")
            })
    }

    @Test func emptyInputsArrayIsRejected() throws {
        let res = try Config.parse(
            """
            [[fallbacks]]
            name = "empty"
            inputs = []
            action-shell = "echo nope"
            """)
        #expect(res.config.fallbacks.count == 0)
        #expect(res.droppedBindings >= 1)
        #expect(
            res.warnings.contains {
                $0.kind == .missingInput && $0.message.contains("at least one")
            })
    }

    @Test func nonArrayInputsIsRejected() throws {
        // `inputs = "cmd - *"` (string, not array) should error.
        let res = try Config.parse(
            """
            [[fallbacks]]
            name = "wrong-type"
            inputs = "cmd - *"
            action-shell = "echo nope"
            """)
        #expect(res.config.fallbacks.count == 0)
        #expect(res.droppedBindings >= 1)
        #expect(
            res.warnings.contains {
                $0.kind == .missingInput && $0.message.contains("must be an array")
            })
    }

    @Test func nonStringElementInInputsIsRejected() throws {
        // `inputs = ["cmd - *", 42]` — one element is an int.
        let res = try Config.parse(
            """
            [[fallbacks]]
            name = "mixed"
            inputs = ["cmd - *", 42]
            action-shell = "echo nope"
            """)
        #expect(res.config.fallbacks.count == 0)
        #expect(res.droppedBindings >= 1)
        #expect(
            res.warnings.contains {
                $0.kind == .missingInput
                    && $0.message.contains("every inputs[] element must be a string")
            })
    }

    // MARK: - Expanded fallbacks fire as normal fallbacks

    @Test func expandedFallbacksMatchAtMatcherLevel() throws {
        let res = try Config.parse(
            """
            [input-aliases]
            ULTRA_LL = "rctrl + ralt + rshift"
            MEGA_RM  = "rctrl + rcmd + ralt"

            [[fallbacks]]
            name = "fb"
            inputs = ["$ULTRA_LL - *", "$MEGA_RM - *"]
            action-shell = "echo undef"
            """)
        let m = Matcher(bindings: [], fallbacks: res.config.fallbacks)

        // ULTRA_LL + any keyboard key (no binding above hits) → fb.
        let hitUltra = m.find(
            .init(
                trigger: .key(0x00),
                modifiers: [.rctrl, .ropt, .rshift],
                bundleID: nil))
        #expect(hitUltra != nil)

        // MEGA_RM + any → fb.
        let hitMega = m.find(
            .init(
                trigger: .key(0x00),
                modifiers: [.rctrl, .rcmd, .ropt],
                bundleID: nil))
        #expect(hitMega != nil)

        // Plain cmd + any → no fb (modset not covered).
        let miss = m.find(
            .init(
                trigger: .key(0x00),
                modifiers: [.lcmd],
                bundleID: nil))
        #expect(miss == nil)
    }
}

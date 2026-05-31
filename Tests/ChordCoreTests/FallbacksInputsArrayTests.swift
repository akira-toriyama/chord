import XCTest
@testable import ChordCore

/// chord 0.8.0+: `[[fallbacks]]` accepts `inputs = ["a", "b", ...]`
/// to collapse N modset feedback rows into one block. Each element
/// becomes a fully-formed fallback with the original action / apps
/// shared verbatim.
final class FallbacksInputsArrayTests: XCTestCase {

    // MARK: - Basic expansion

    func testInputsArrayExpandsToOneFallbackPerEntry() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL   = "rctrl + ralt + rshift"
        MIRACLE_LM = "rctrl + rcmd + rshift"

        [[fallbacks]]
        name = "undefined feedback"
        inputs = ["$ULTRA_LL - *", "$MIRACLE_LM - *"]
        action-shell = "afplay undefined.wav"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.fallbacks.count, 2,
                       "2-entry inputs[] → 2 fallback bindings")
        // Each carries the same action.
        for fb in res.config.fallbacks {
            if case .shell(let body) = fb.action {
                XCTAssertEqual(body, "afplay undefined.wav")
            } else {
                XCTFail("expected shell action, got \(fb.action)")
            }
        }
        // Names disambiguated by the original input string.
        let names = res.config.fallbacks.map(\.name)
        XCTAssertEqual(names, [
            "undefined feedback — $ULTRA_LL - *",
            "undefined feedback — $MIRACLE_LM - *",
        ])
        // inputRaw round-trips (used by --list --json + warnings).
        XCTAssertEqual(res.config.fallbacks[0].inputRaw, "$ULTRA_LL - *")
        XCTAssertEqual(res.config.fallbacks[1].inputRaw, "$MIRACLE_LM - *")
    }

    func testInputsArrayPreservesAppsAndActionAlias() throws {
        let res = try Config.parse("""
        [action-aliases]
        beep = "afplay beep.wav"

        [[fallbacks]]
        name = "feedback"
        inputs = ["cmd - *", "opt - *"]
        action-shell = "@beep"
        apps = ["com.apple.Terminal"]
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.fallbacks.count, 2)
        for fb in res.config.fallbacks {
            XCTAssertEqual(fb.apps, ["com.apple.Terminal"])
            XCTAssertEqual(fb.aliasName, "beep",
                           "@alias resolved per expanded row")
            if case .shell(let body) = fb.action {
                XCTAssertEqual(body, "afplay beep.wav")
            } else {
                XCTFail("expected shell, got \(fb.action)")
            }
        }
    }

    func testSingleInputStillWorks() throws {
        // Regression: classic single `input = "..."` path is unchanged.
        let res = try Config.parse("""
        [[fallbacks]]
        name = "lone fallback"
        input = "cmd - *"
        action-shell = "echo lone"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.fallbacks.count, 1)
        XCTAssertEqual(res.config.fallbacks[0].name, "lone fallback")
        // No " — <input>" suffix when the row used single input.
        XCTAssertFalse(res.config.fallbacks[0].name.contains(" — "))
    }

    // MARK: - Validation: error paths

    func testInputAndInputsAreMutuallyExclusive() throws {
        let res = try Config.parse("""
        [[fallbacks]]
        name = "conflict"
        input = "cmd - *"
        inputs = ["opt - *"]
        action-shell = "echo nope"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 0)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .missingInput &&
            $0.message.contains("mutually exclusive")
        })
    }

    func testEmptyInputsArrayIsRejected() throws {
        let res = try Config.parse("""
        [[fallbacks]]
        name = "empty"
        inputs = []
        action-shell = "echo nope"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 0)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .missingInput &&
            $0.message.contains("at least one")
        })
    }

    func testNonArrayInputsIsRejected() throws {
        // `inputs = "cmd - *"` (string, not array) should error.
        let res = try Config.parse("""
        [[fallbacks]]
        name = "wrong-type"
        inputs = "cmd - *"
        action-shell = "echo nope"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 0)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .missingInput &&
            $0.message.contains("must be an array")
        })
    }

    func testNonStringElementInInputsIsRejected() throws {
        // `inputs = ["cmd - *", 42]` — one element is an int.
        let res = try Config.parse("""
        [[fallbacks]]
        name = "mixed"
        inputs = ["cmd - *", 42]
        action-shell = "echo nope"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 0)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .missingInput &&
            $0.message.contains("every inputs[] element must be a string")
        })
    }

    // MARK: - Expanded fallbacks fire as normal fallbacks

    func testExpandedFallbacksMatchAtMatcherLevel() throws {
        let res = try Config.parse("""
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
        let hitUltra = m.find(.init(trigger: .key(0x00),
                                    modifiers: [.rctrl, .ropt, .rshift],
                                    bundleID: nil))
        XCTAssertNotNil(hitUltra)

        // MEGA_RM + any → fb.
        let hitMega = m.find(.init(trigger: .key(0x00),
                                   modifiers: [.rctrl, .rcmd, .ropt],
                                   bundleID: nil))
        XCTAssertNotNil(hitMega)

        // Plain cmd + any → no fb (modset not covered).
        let miss = m.find(.init(trigger: .key(0x00),
                                modifiers: [.lcmd],
                                bundleID: nil))
        XCTAssertNil(miss)
    }
}

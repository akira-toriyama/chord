import XCTest
@testable import ChordCore

/// chord 0.9.0+: `input = "$ULTRA_LL"` (no primary key) parses as
/// `Trigger.modifiersOnly` and fires on the OS-side modifier mask
/// **entering** the binding's mask. Optional `onUpAction` fires on
/// the reverse transition. Controller-side timing (flagsChanged
/// routing) is exercised via Controller integration, not here —
/// these tests pin the **parse + Matcher.Event shape contract**.
final class ModifiersOnlyTriggerTests: XCTestCase {

    // MARK: - Parse

    func testBareModifierAliasParsesAsModifiersOnly() throws {
        let res = try Config.parse("""
        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"

        [[bindings]]
        name = "enter ULTRA_LL"
        input = "$ULTRA_LL"
        action-set-var = "ultra-active"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 1)
        let b = res.config.bindings[0]
        XCTAssertEqual(b.trigger, .modifiersOnly)
        XCTAssertEqual(b.modifiers, [.rctrl, .ropt, .rshift])
    }

    func testBareModifierChainParsesAsModifiersOnly() throws {
        // Direct modifier-only without alias: `cmd + opt`.
        let res = try Config.parse("""
        [[bindings]]
        name = "cmd-opt enter"
        input = "cmd + opt"
        action-set-var = "wm-armed"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        XCTAssertEqual(b.trigger, .modifiersOnly)
        XCTAssertEqual(b.modifiers, [.cmd, .opt])
    }

    func testRegularBindingsStillParse() throws {
        // Regression: existing `mods - key` form is unchanged.
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-noop = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .key = res.config.bindings[0].trigger {
            // OK
        } else { XCTFail("expected .key trigger") }
    }

    // MARK: - Modifiers-only does not match key/mouse/scroll events

    func testModifiersOnlyTriggerNotHitByKeyEvent() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "mods"
        input = "cmd + opt"
        action-set-var = "wm"
        """)
        let m = Matcher(bindings: res.config.bindings)
        // A regular key event must not fire a modifiers-only binding
        // — Trigger equality fails (.key != .modifiersOnly).
        let hit = m.find(.init(trigger: .key(0x07),
                               modifiers: [.lcmd, .lopt],
                               bundleID: nil))
        XCTAssertNil(hit)
    }

    // MARK: - Schema round-trip

    func testSchemaEmitsModifiersOnlyKind() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "mods"
        input = "cmd + opt"
        action-set-var = "wm"
        """)
        let input = try XCTUnwrap(b["input"] as? [String: Any])
        let trigger = try XCTUnwrap(input["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["kind"] as? String, "modifiersOnly")
    }

    // MARK: - Fallbacks reject modifier-only triggers

    func testFallbacksRejectModifierOnlyInput() throws {
        // [[fallbacks]] is for "any key under this modset" wildcard;
        // a modifier-only fallback would be semantically the same as
        // the prefix check itself — disallow.
        let res = try Config.parse("""
        [[fallbacks]]
        name = "bad"
        input = "cmd + opt"
        action-shell = "echo"
        """)
        XCTAssertEqual(res.config.fallbacks.count, 0)
    }
}

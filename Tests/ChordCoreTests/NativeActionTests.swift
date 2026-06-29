import Testing
@testable import ChordCore

/// chord 0.9.0+: `action-mission-control` / `action-screenshot` /
/// `action-spotlight` desugar to fixed `.keys` actions targeting the
/// macOS default keyboard shortcut. No new Action enum case; the
/// JSON / Schema surface sees a plain keys binding.
///
/// Caveat (documented in glossary): if the user has remapped the
/// underlying shortcut in System Settings → Keyboard, the action
/// effectively re-binds to whatever they assigned.
@Suite struct NativeActionTests {

    // MARK: - Mission Control

    @Test func missionControlAllWindowsDesugarsToCtrlUp() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "mc"
            input = "$ULTRA_LL - m"
            action-mission-control = "show-all-windows"

            [input-aliases]
            ULTRA_LL = "rctrl + ralt + rshift"
            """)
        #expect(res.droppedBindings == 0)
        let b = res.config.bindings[0]
        if case .keys(let mods, let kc) = b.action {
            #expect(mods == [.ctrl])
            #expect(kc == 0x7E)  // arrow_up
        } else {
            Issue.record("expected .keys")
        }
        #expect(b.actionRaw == "action-mission-control:show-all-windows")
    }

    @Test func missionControlAppWindowsDesugarsToCtrlDown() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "app-exp"
            input = "cmd + opt - m"
            action-mission-control = "show-app-windows"
            """)
        #expect(res.droppedBindings == 0)
        if case .keys(_, let kc) = res.config.bindings[0].action {
            #expect(kc == 0x7D)  // arrow_down
        } else {
            Issue.record("expected .keys")
        }
    }

    @Test func missionControlInvalidVariantDrops() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - m"
            action-mission-control = "windows-on-mars"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .actionKeysParseError && $0.message.contains("windows-on-mars")
            })
    }

    // MARK: - Screenshot

    @Test func screenshotSelection() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "shot"
            input = "cmd + ctrl - 4"
            action-screenshot = "selection"
            """)
        #expect(res.droppedBindings == 0)
        if case .keys(let mods, let kc) = res.config.bindings[0].action {
            #expect(mods == [.cmd, .shift])
            #expect(kc == 0x15)  // '4'
        } else {
            Issue.record("expected .keys")
        }
    }

    @Test func screenshotScreen() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "shot"
            input = "cmd + ctrl - 3"
            action-screenshot = "screen"
            """)
        #expect(res.droppedBindings == 0)
        if case .keys(_, let kc) = res.config.bindings[0].action {
            #expect(kc == 0x14)  // '3'
        } else {
            Issue.record("expected .keys")
        }
    }

    @Test func screenshotInvalidVariantDrops() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - s"
            action-screenshot = "everything"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .actionKeysParseError })
    }

    // MARK: - Spotlight

    @Test func spotlightDesugarsToCmdSpace() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "spot"
            input = "cmd - space"
            action-spotlight = true
            """)
        #expect(res.droppedBindings == 0)
        if case .keys(let mods, let kc) = res.config.bindings[0].action {
            #expect(mods == [.cmd])
            #expect(kc == 0x31)  // 'space'
        } else {
            Issue.record("expected .keys")
        }
    }

    // MARK: - Schema

    @Test func schemaShowsDesugaredKeysWithSemanticRaw() throws {
        let b = try firstBinding(
            """
            [[bindings]]
            name = "mc"
            input = "cmd - m"
            action-mission-control = "show-all-windows"
            """)
        let action = try #require(b["action"] as? [String: Any])
        // JSON shows plain .keys, but `raw` preserves the original
        // native-action intent so consumers can disambiguate.
        #expect(action["kind"] as? String == "keys")
        #expect(action["raw"] as? String == "action-mission-control:show-all-windows")
    }
}

import XCTest
@testable import ChordCore

/// chord 0.9.0+: `action-mission-control` / `action-screenshot` /
/// `action-spotlight` desugar to fixed `.keys` actions targeting the
/// macOS default keyboard shortcut. No new Action enum case; the
/// JSON / Schema surface sees a plain keys binding.
///
/// Caveat (documented in glossary): if the user has remapped the
/// underlying shortcut in System Settings → Keyboard, the action
/// effectively re-binds to whatever they assigned.
final class NativeActionTests: XCTestCase {

    // MARK: - Mission Control

    func testMissionControlAllWindowsDesugarsToCtrlUp() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "mc"
        input = "$ULTRA_LL - m"
        action-mission-control = "show-all-windows"

        [input-aliases]
        ULTRA_LL = "rctrl + ralt + rshift"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        let b = res.config.bindings[0]
        if case .keys(let mods, let kc) = b.action {
            XCTAssertEqual(mods, [.ctrl])
            XCTAssertEqual(kc, 0x7E)   // arrow_up
        } else { XCTFail("expected .keys") }
        XCTAssertEqual(b.actionRaw,
                       "action-mission-control:show-all-windows")
    }

    func testMissionControlAppWindowsDesugarsToCtrlDown() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "app-exp"
        input = "cmd + opt - m"
        action-mission-control = "show-app-windows"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .keys(_, let kc) = res.config.bindings[0].action {
            XCTAssertEqual(kc, 0x7D)   // arrow_down
        } else { XCTFail("expected .keys") }
    }

    func testMissionControlInvalidVariantDrops() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - m"
        action-mission-control = "windows-on-mars"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .actionKeysParseError &&
            $0.message.contains("windows-on-mars")
        })
    }

    // MARK: - Screenshot

    func testScreenshotSelection() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "shot"
        input = "cmd + ctrl - 4"
        action-screenshot = "selection"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .keys(let mods, let kc) = res.config.bindings[0].action {
            XCTAssertEqual(mods, [.cmd, .shift])
            XCTAssertEqual(kc, 0x15)   // '4'
        } else { XCTFail("expected .keys") }
    }

    func testScreenshotScreen() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "shot"
        input = "cmd + ctrl - 3"
        action-screenshot = "screen"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .keys(_, let kc) = res.config.bindings[0].action {
            XCTAssertEqual(kc, 0x14)   // '3'
        } else { XCTFail("expected .keys") }
    }

    func testScreenshotInvalidVariantDrops() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "bad"
        input = "cmd - s"
        action-screenshot = "everything"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .actionKeysParseError })
    }

    // MARK: - Spotlight

    func testSpotlightDesugarsToCmdSpace() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "spot"
        input = "cmd - space"
        action-spotlight = true
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        if case .keys(let mods, let kc) = res.config.bindings[0].action {
            XCTAssertEqual(mods, [.cmd])
            XCTAssertEqual(kc, 0x31)   // 'space'
        } else { XCTFail("expected .keys") }
    }

    // MARK: - Schema

    func testSchemaShowsDesugaredKeysWithSemanticRaw() throws {
        let b = try firstBinding("""
        [[bindings]]
        name = "mc"
        input = "cmd - m"
        action-mission-control = "show-all-windows"
        """)
        let action = try XCTUnwrap(b["action"] as? [String: Any])
        // JSON shows plain .keys, but `raw` preserves the original
        // native-action intent so consumers can disambiguate.
        XCTAssertEqual(action["kind"] as? String, "keys")
        XCTAssertEqual(action["raw"] as? String,
                       "action-mission-control:show-all-windows")
    }
}

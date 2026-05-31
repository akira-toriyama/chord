import XCTest
@testable import ChordCore

/// chord 0.8.0+: `[[bindings.per-app]]` AoT sub-rows expand the
/// parent `[[bindings]]` row into N siblings (one per OS), each
/// scoped via `apps = [bundle-id]`. Each entry's action-* / when-var
/// / hold-while fields layer over the base row.
final class PerAppTableTests: XCTestCase {

    // MARK: - Basic expansion

    func testPerAppExpandsToOneBindingPerEntry() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "tab-left"
        input = "cmd + opt - c"

          [[bindings.per-app]]
          bundle-id = "com.google.Chrome"
          action-keys = "ctrl + shift - tab"

          [[bindings.per-app]]
          bundle-id = "com.microsoft.VSCode"
          action-keys = "cmd + shift - ["
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 2,
                       "2 per-app entries → 2 expanded bindings")

        let names = res.config.bindings.map(\.name)
        XCTAssertEqual(names, [
            "tab-left — com.google.Chrome",
            "tab-left — com.microsoft.VSCode",
        ])

        // Each carries its own apps + action.
        XCTAssertEqual(res.config.bindings[0].apps, ["com.google.Chrome"])
        XCTAssertEqual(res.config.bindings[1].apps, ["com.microsoft.VSCode"])
        // Both share the base input.
        XCTAssertEqual(res.config.bindings[0].inputRaw, "cmd + opt - c")
        XCTAssertEqual(res.config.bindings[1].inputRaw, "cmd + opt - c")
    }

    func testPerAppInheritsBaseRowAction() throws {
        // When a per-app entry omits the action, it should inherit
        // the base row's action.
        let res = try Config.parse("""
        [[bindings]]
        name = "shared-action"
        input = "cmd - h"
        action-keys = "left"

          [[bindings.per-app]]
          bundle-id = "com.apple.Terminal"

          [[bindings.per-app]]
          bundle-id = "com.googlecode.iterm2"
          action-keys = "backspace"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 2)

        let byApp = Dictionary(uniqueKeysWithValues:
            res.config.bindings.compactMap { b -> (String, Binding)? in
                guard let a = b.apps?.first else { return nil }
                return (a, b)
            })
        // Terminal inherited base "left".
        if case .keys(_, let kc) = byApp["com.apple.Terminal"]?.action {
            XCTAssertEqual(kc, 0x7B)  // arrow_left
        } else { XCTFail("Terminal: expected .keys") }
        // iTerm overrode with "backspace".
        if case .keys(_, let kc) = byApp["com.googlecode.iterm2"]?.action {
            XCTAssertEqual(kc, 0x33)
        } else { XCTFail("iTerm: expected .keys") }
    }

    func testPerAppEntryCanCarryActionShell() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "browser-back"
        input = "cmd + ctrl - b"

          [[bindings.per-app]]
          bundle-id = "com.apple.Safari"
          action-shell = "echo safari back"

          [[bindings.per-app]]
          bundle-id = "com.google.Chrome"
          action-shell = "echo chrome back"
        """)
        XCTAssertEqual(res.droppedBindings, 0)
        XCTAssertEqual(res.config.bindings.count, 2)
        if case .shell(let s) = res.config.bindings[0].action {
            XCTAssertEqual(s, "echo safari back")
        } else { XCTFail("safari: expected .shell") }
        if case .shell(let s) = res.config.bindings[1].action {
            XCTAssertEqual(s, "echo chrome back")
        } else { XCTFail("chrome: expected .shell") }
    }

    func testPerAppDoesNotAffectRowsWithoutIt() throws {
        // Regression: a normal `[[bindings]]` row without `per-app`
        // is unchanged.
        let res = try Config.parse("""
        [[bindings]]
        name = "plain"
        input = "cmd - x"
        action-noop = true
        """)
        XCTAssertEqual(res.config.bindings.count, 1)
        XCTAssertNil(res.config.bindings[0].apps)
        XCTAssertEqual(res.config.bindings[0].name, "plain")
    }

    // MARK: - Validation: error paths

    func testAppsAndPerAppAreMutuallyExclusive() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "conflict"
        input = "cmd - x"
        apps = ["com.foo"]

          [[bindings.per-app]]
          bundle-id = "com.google.Chrome"
          action-keys = "left"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertGreaterThanOrEqual(res.droppedBindings, 1)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .perAppParseError &&
            $0.message.contains("mutually exclusive")
        })
    }

    func testMissingBundleIdDropsTheWholeBinding() throws {
        // Spec choice: a malformed per-app entry invalidates the
        // entire row (drops every expansion) so the user can't end
        // up with a partial fan-out without knowing.
        let res = try Config.parse("""
        [[bindings]]
        name = "partial"
        input = "cmd - x"

          [[bindings.per-app]]
          action-keys = "left"

          [[bindings.per-app]]
          bundle-id = "com.google.Chrome"
          action-keys = "right"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains {
            $0.kind == .perAppParseError &&
            $0.message.contains("bundle-id")
        })
    }

    func testEmptyBundleIdRejected() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "empty-id"
        input = "cmd - x"

          [[bindings.per-app]]
          bundle-id = ""
          action-keys = "left"
        """)
        XCTAssertEqual(res.config.bindings.count, 0)
        XCTAssertTrue(res.warnings.contains { $0.kind == .perAppParseError })
    }

    // MARK: - Per-app + sequence-prefix collision

    func testPerAppCollidingWithSequencePrefixIsDropped() throws {
        // Sequence prefix wins over a regular per-app expansion that
        // shares (trigger, modifiers). Each per-app expansion gets
        // dropped independently with a warning.
        let res = try Config.parse("""
        [[sequence]]
        name = "leader"
        prefix = "cmd + opt - j"
        timeout-ms = 500
          [[sequence.bindings]]
          input = "k"
          action-keys = "return"

        [[bindings]]
        name = "tab-left"
        input = "cmd + opt - j"

          [[bindings.per-app]]
          bundle-id = "com.google.Chrome"
          action-keys = "left"

          [[bindings.per-app]]
          bundle-id = "com.microsoft.VSCode"
          action-keys = "right"
        """)
        // 2 sequence-expanded survive, 2 per-app expansions drop.
        XCTAssertEqual(res.config.bindings.count, 2)
        XCTAssertEqual(res.droppedBindings, 2)
        // Both per-app drops carry sequence-collision warnings.
        let collisions = res.warnings.filter {
            $0.kind == .sequenceParseError &&
            $0.message.contains("[[sequence]] prefix")
        }
        XCTAssertEqual(collisions.count, 2)
    }

    // MARK: - Matcher end-to-end

    func testPerAppMatcherSelectsBindingByFrontmost() throws {
        let res = try Config.parse("""
        [[bindings]]
        name = "tab-left"
        input = "cmd + opt - c"

          [[bindings.per-app]]
          bundle-id = "com.google.Chrome"
          action-keys = "ctrl + shift - tab"

          [[bindings.per-app]]
          bundle-id = "com.microsoft.VSCode"
          action-keys = "cmd + shift - ["
        """)
        let m = Matcher(bindings: res.config.bindings)
        let chrome = m.find(.init(trigger: .key(0x08),         // 'c'
                                  modifiers: [.lcmd, .lopt],
                                  bundleID: "com.google.Chrome"))
        XCTAssertEqual(chrome?.name, "tab-left — com.google.Chrome")
        let vscode = m.find(.init(trigger: .key(0x08),
                                  modifiers: [.lcmd, .lopt],
                                  bundleID: "com.microsoft.VSCode"))
        XCTAssertEqual(vscode?.name, "tab-left — com.microsoft.VSCode")
        let other = m.find(.init(trigger: .key(0x08),
                                 modifiers: [.lcmd, .lopt],
                                 bundleID: "com.apple.Terminal"))
        XCTAssertNil(other, "per-app: non-matching frontmost → no fire")
    }
}

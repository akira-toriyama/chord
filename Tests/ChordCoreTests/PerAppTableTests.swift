import Testing
@testable import ChordCore

/// chord 0.8.0+: `[[bindings.per-app]]` AoT sub-rows expand the
/// parent `[[bindings]]` row into N siblings (one per OS), each
/// scoped via `apps = [bundle-id]`. Each entry's action-* / when-var
/// / hold-while fields layer over the base row.
@Suite struct PerAppTableTests {

    // MARK: - Basic expansion

    @Test func perAppExpandsToOneBindingPerEntry() throws {
        let res = try Config.parse(
            """
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
        #expect(res.droppedBindings == 0)
        #expect(
            res.config.bindings.count == 2,
            "2 per-app entries → 2 expanded bindings")

        let names = res.config.bindings.map(\.name)
        #expect(
            names == [
                "tab-left — com.google.Chrome",
                "tab-left — com.microsoft.VSCode"
            ])

        // Each carries its own apps + action.
        #expect(res.config.bindings[0].apps == ["com.google.Chrome"])
        #expect(res.config.bindings[1].apps == ["com.microsoft.VSCode"])
        // Both share the base input.
        #expect(res.config.bindings[0].inputRaw == "cmd + opt - c")
        #expect(res.config.bindings[1].inputRaw == "cmd + opt - c")
    }

    @Test func perAppInheritsBaseRowAction() throws {
        // When a per-app entry omits the action, it should inherit
        // the base row's action.
        let res = try Config.parse(
            """
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
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings.count == 2)

        let byApp = Dictionary(
            uniqueKeysWithValues:
                res.config.bindings.compactMap { b -> (String, Binding)? in
                    guard let a = b.apps?.first else { return nil }
                    return (a, b)
                })
        // Terminal inherited base "left".
        if case .keys(_, let kc) = byApp["com.apple.Terminal"]?.action {
            #expect(kc == 0x7B)  // arrow_left
        } else {
            Issue.record("Terminal: expected .keys")
        }
        // iTerm overrode with "backspace".
        if case .keys(_, let kc) = byApp["com.googlecode.iterm2"]?.action {
            #expect(kc == 0x33)
        } else {
            Issue.record("iTerm: expected .keys")
        }
    }

    @Test func perAppEntryCanCarryActionShell() throws {
        let res = try Config.parse(
            """
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
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings.count == 2)
        if case .shell(let s) = res.config.bindings[0].action {
            #expect(s == "echo safari back")
        } else {
            Issue.record("safari: expected .shell")
        }
        if case .shell(let s) = res.config.bindings[1].action {
            #expect(s == "echo chrome back")
        } else {
            Issue.record("chrome: expected .shell")
        }
    }

    @Test func perAppDoesNotAffectRowsWithoutIt() throws {
        // Regression: a normal `[[bindings]]` row without `per-app`
        // is unchanged.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "plain"
            input = "cmd - x"
            action-noop = true
            """)
        #expect(res.config.bindings.count == 1)
        #expect(res.config.bindings[0].apps == nil)
        #expect(res.config.bindings[0].name == "plain")
    }

    // MARK: - Validation: error paths

    @Test func appsAndPerAppAreMutuallyExclusive() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "conflict"
            input = "cmd - x"
            apps = ["com.foo"]

              [[bindings.per-app]]
              bundle-id = "com.google.Chrome"
              action-keys = "left"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.droppedBindings >= 1)
        #expect(
            res.warnings.contains {
                $0.kind == .perAppParseError && $0.message.contains("mutually exclusive")
            })
    }

    @Test func missingBundleIdDropsTheWholeBinding() throws {
        // Spec choice: a malformed per-app entry invalidates the
        // entire row (drops every expansion) so the user can't end
        // up with a partial fan-out without knowing.
        let res = try Config.parse(
            """
            [[bindings]]
            name = "partial"
            input = "cmd - x"

              [[bindings.per-app]]
              action-keys = "left"

              [[bindings.per-app]]
              bundle-id = "com.google.Chrome"
              action-keys = "right"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(
            res.warnings.contains {
                $0.kind == .perAppParseError && $0.message.contains("bundle-id")
            })
    }

    @Test func emptyBundleIdRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "empty-id"
            input = "cmd - x"

              [[bindings.per-app]]
              bundle-id = ""
              action-keys = "left"
            """)
        #expect(res.config.bindings.count == 0)
        #expect(res.warnings.contains { $0.kind == .perAppParseError })
    }

    // MARK: - Per-app + sequence-prefix collision

    @Test func perAppCollidingWithSequencePrefixIsDropped() throws {
        // Sequence prefix wins over a regular per-app expansion that
        // shares (trigger, modifiers). Each per-app expansion gets
        // dropped independently with a warning.
        let res = try Config.parse(
            """
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
        #expect(res.config.bindings.count == 2)
        #expect(res.droppedBindings == 2)
        // Both per-app drops carry sequence-collision warnings.
        let collisions = res.warnings.filter {
            $0.kind == .sequenceParseError && $0.message.contains("[[sequence]] prefix")
        }
        #expect(collisions.count == 2)
    }

    // MARK: - Matcher end-to-end

    @Test func perAppMatcherSelectsBindingByFrontmost() throws {
        let res = try Config.parse(
            """
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
        let chrome = m.find(
            .init(
                trigger: .key(0x08),  // 'c'
                modifiers: [.lcmd, .lopt],
                bundleID: "com.google.Chrome"))
        #expect(chrome?.name == "tab-left — com.google.Chrome")
        let vscode = m.find(
            .init(
                trigger: .key(0x08),
                modifiers: [.lcmd, .lopt],
                bundleID: "com.microsoft.VSCode"))
        #expect(vscode?.name == "tab-left — com.microsoft.VSCode")
        let other = m.find(
            .init(
                trigger: .key(0x08),
                modifiers: [.lcmd, .lopt],
                bundleID: "com.apple.Terminal"))
        #expect(other == nil, "per-app: non-matching frontmost → no fire")
    }
}

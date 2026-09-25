import Testing
@testable import ChordCore

/// `[battery]` (chord 3.1.0+): the split peripheral battery watch table.
/// Both keys are required; any defect disables the whole table with a
/// warning and leaves the rest of the config alone.
@Suite struct BatteryConfigTests {
    private func kinds(_ r: Config.ParseResult) -> [ConfigWarning.Kind] {
        r.warnings.map(\.kind)
    }

    @Test func absentTableIsNil() throws {
        let r = try Config.parse(
            """
            [[bindings]]
            name = "x"
            input = "cmd - x"
            action-noop = true
            """)
        #expect(r.config.battery == nil)
        #expect(r.warnings.isEmpty)
    }

    @Test func validTableLoads() throws {
        let r = try Config.parse(
            """
            [battery]
            threshold = 10
            action-shell = "imprint-battery-notify"
            """)
        #expect(
            r.config.battery
                == ChordConfig.Battery(threshold: 10, actionShell: "imprint-battery-notify"))
        #expect(r.warnings.isEmpty)
        #expect(r.droppedBindings == 0)
    }

    @Test func boundsAreInclusive() throws {
        let low = try Config.parse("[battery]\nthreshold = 1\naction-shell = \"x\"\n")
        #expect(low.config.battery?.threshold == 1)
        let high = try Config.parse("[battery]\nthreshold = 100\naction-shell = \"x\"\n")
        #expect(high.config.battery?.threshold == 100)
    }

    /// `action-shell` resolves `@name` and `@name(args)` exactly like a
    /// binding's — the same `[action-aliases]` table, the same resolver.
    @Test func actionShellResolvesAliases() throws {
        let bare = try Config.parse(
            """
            [action-aliases]
            notify = "terminal-notifier -title Imprint -message low"

            [battery]
            threshold = 10
            action-shell = "@notify"
            """)
        #expect(bare.config.battery?.actionShell == "terminal-notifier -title Imprint -message low")
        #expect(bare.warnings.isEmpty)

        let call = try Config.parse(
            """
            [action-aliases]
            notify-with = "terminal-notifier -title {{1}}"

            [battery]
            threshold = 10
            action-shell = "@notify-with(Imprint)"
            """)
        #expect(call.config.battery?.actionShell == "terminal-notifier -title Imprint")
        #expect(call.warnings.isEmpty)
    }

    @Test func undefinedAliasDisablesTheWatch() throws {
        let r = try Config.parse("[battery]\nthreshold = 10\naction-shell = \"@nope\"\n")
        #expect(r.config.battery == nil)
        #expect(kinds(r) == [.undefinedActionAlias])
        #expect(r.warnings[0].message.contains("[battery] 'action-shell'"))
        #expect(r.warnings[0].message.contains("'@nope'"))
    }

    @Test func aliasCallErrorDisablesTheWatch() throws {
        let r = try Config.parse(
            """
            [action-aliases]
            notify-with = "terminal-notifier -title {{1}}"

            [battery]
            threshold = 10
            action-shell = "@notify-with"
            """)
        #expect(r.config.battery == nil)
        #expect(kinds(r) == [.actionAliasCallError])
    }

    @Test func missingThresholdDisablesTheWatch() throws {
        let r = try Config.parse("[battery]\naction-shell = \"x\"\n")
        #expect(r.config.battery == nil)
        #expect(kinds(r) == [.batteryInvalid])
        #expect(r.warnings[0].message.contains("'threshold'"))
        #expect(r.warnings[0].message.contains("config.toml:1"))  // the table header
    }

    @Test func thresholdOutOfRangeDisablesTheWatch() throws {
        for bad in ["0", "101", "-5"] {
            let r = try Config.parse("[battery]\nthreshold = \(bad)\naction-shell = \"x\"\n")
            #expect(r.config.battery == nil, "threshold = \(bad)")
            #expect(kinds(r) == [.batteryInvalid], "threshold = \(bad)")
            #expect(r.warnings[0].message.contains("outside 1–100"))
            #expect(r.warnings[0].message.contains("config.toml:2"))
        }
    }

    /// A wrong TOML type is the existing `field-type-mismatch` (the loader
    /// reads via `asInt` / `asString`), not a second battery kind.
    @Test func wrongTypesDisableTheWatch() throws {
        let string = try Config.parse("[battery]\nthreshold = \"10\"\naction-shell = \"x\"\n")
        #expect(string.config.battery == nil)
        #expect(kinds(string) == [.fieldTypeMismatch])
        #expect(string.warnings[0].message.contains("expected integer, got string"))
        #expect(string.warnings[0].message.contains("battery watch disabled"))

        let float = try Config.parse("[battery]\nthreshold = 10.5\naction-shell = \"x\"\n")
        #expect(float.config.battery == nil)
        #expect(kinds(float) == [.fieldTypeMismatch])

        let command = try Config.parse("[battery]\nthreshold = 10\naction-shell = 7\n")
        #expect(command.config.battery == nil)
        #expect(kinds(command) == [.fieldTypeMismatch])
        #expect(command.warnings[0].message.contains("expected string, got integer"))
    }

    @Test func missingOrEmptyActionDisablesTheWatch() throws {
        let missing = try Config.parse("[battery]\nthreshold = 10\n")
        #expect(missing.config.battery == nil)
        #expect(kinds(missing) == [.batteryInvalid])
        #expect(missing.warnings[0].message.contains("'action-shell' is required"))

        let empty = try Config.parse("[battery]\nthreshold = 10\naction-shell = \"  \"\n")
        #expect(empty.config.battery == nil)
        #expect(kinds(empty) == [.batteryInvalid])
        #expect(empty.warnings[0].message.contains("empty command"))

        // A newline-only command is a zsh no-op, not a command.
        let newline = try Config.parse("[battery]\nthreshold = 10\naction-shell = \"\\n\"\n")
        #expect(newline.config.battery == nil)
        #expect(kinds(newline) == [.batteryInvalid])
    }

    /// `[[battery]]` and `battery = 5` name a known section in the wrong
    /// shape; the structural check passes them, so the parser says why the
    /// watch never runs.
    @Test func wrongTableShapeIsReported() throws {
        let aot = try Config.parse("[[battery]]\nthreshold = 10\naction-shell = \"x\"\n")
        #expect(aot.config.battery == nil)
        #expect(kinds(aot) == [.batteryInvalid])
        #expect(aot.warnings[0].message.contains("got array-of-tables"))
        #expect(aot.warnings[0].message.contains("config.toml:1"))

        let scalar = try Config.parse("battery = 5\n")
        #expect(scalar.config.battery == nil)
        #expect(kinds(scalar) == [.batteryInvalid])
        #expect(scalar.warnings[0].message.contains("got integer"))
    }

    /// A bare `[battery]` header has no entries, so the TOML tree drops
    /// the table — the span index still has the header, and both missing
    /// keys are reported rather than the header being a silent no-op.
    @Test func everyDefectIsReported() throws {
        let r = try Config.parse("[battery]\n")
        #expect(r.config.battery == nil)
        #expect(kinds(r) == [.batteryInvalid, .batteryInvalid])
        #expect(r.warnings.allSatisfy { $0.message.contains("config.toml:1") })
    }

    /// An unknown key is a typo warning, as in `[options]` — the watch
    /// still runs on the keys it understands.
    @Test func unknownKeyWarnsButKeepsTheWatch() throws {
        let r = try Config.parse(
            """
            [battery]
            threshhold = 5
            threshold = 10
            action-shell = "x"
            """)
        #expect(r.config.battery?.threshold == 10)
        #expect(kinds(r) == [.unknownKey])
        #expect(r.warnings[0].message.contains("[battery] 'threshhold'"))
        #expect(r.warnings[0].message.contains("config.toml:2"))
        #expect(r.warnings[0].message.contains("known: action-shell, threshold"))
    }

    /// Bindings are untouched by a broken `[battery]`: nothing is dropped,
    /// the warning is the only trace.
    @Test func aBrokenTableDropsNoBinding() throws {
        let r = try Config.parse(
            """
            [battery]
            threshold = 0
            action-shell = "x"

            [[bindings]]
            name = "still here"
            input = "cmd - x"
            action-noop = true
            """)
        #expect(r.config.bindings.count == 1)
        #expect(r.droppedBindings == 0)
        #expect(kinds(r) == [.batteryInvalid])
    }
}

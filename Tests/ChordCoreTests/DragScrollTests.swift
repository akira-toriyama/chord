import Testing

@testable import ChordCore

/// chord 0.12.0+ `action-drag-scroll`: hold the trigger, pin the cursor,
/// turn pointer motion into scrolling.
///
/// Two things are pinned here. The **arithmetic** (`DragScrollAccumulator`)
/// — the sub-pixel carry is what makes `speed < 1` usable at all, and the
/// axis filter has to drop rather than bank the discarded axis. And the
/// **parse-time refusals** — drag-scroll owns a whole down/up span, so
/// every shape that would leave the mode without an edge to close it has
/// to be rejected at load rather than wedging the pointer at runtime.
@Suite struct DragScrollTests {

    // MARK: - accumulator

    @Test func wholePixelDeltasPassStraightThrough() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec())
        let tick = acc.step(MotionDelta(dx: 3, dy: -7))
        #expect(tick == ScrollTick(vertical: -7, horizontal: 3))
    }

    @Test func subPixelMotionAccumulatesInsteadOfVanishing() {
        // speed 0.25: no single 1px delta reaches a whole scroll pixel, so
        // truncating per-event would scroll exactly zero forever.
        var acc = DragScrollAccumulator(spec: DragScrollSpec(speed: 0.25))
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == nil)
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == nil)
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == nil)
        // Fourth event completes the pixel.
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == ScrollTick(vertical: 1, horizontal: 0))
        // …and the carry restarts from zero, not from the spent remainder.
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == nil)
    }

    @Test func residualCarriesTheFractionNotTheWholePixel() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec(speed: 1.5))
        // 1.5 → post 1, carry 0.5
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == ScrollTick(vertical: 1, horizontal: 0))
        // 0.5 + 1.5 = 2.0 → post 2, carry 0
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == ScrollTick(vertical: 2, horizontal: 0))
    }

    @Test func speedScalesTheDelta() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec(speed: 3))
        #expect(acc.step(MotionDelta(dx: 2, dy: 2)) == ScrollTick(vertical: 6, horizontal: 6))
    }

    @Test func invertFlipsBothAxesTogether() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec(invert: true))
        #expect(acc.step(MotionDelta(dx: 4, dy: 5)) == ScrollTick(vertical: -5, horizontal: -4))
    }

    @Test func verticalAxisDiscardsHorizontalRatherThanBankingIt() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec(axis: .vertical))
        #expect(acc.step(MotionDelta(dx: 9, dy: 0)) == nil)
        // If the 9 had been banked, this would surface it now.
        #expect(acc.step(MotionDelta(dx: 0, dy: 2)) == ScrollTick(vertical: 2, horizontal: 0))
    }

    @Test func horizontalAxisDiscardsVertical() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec(axis: .horizontal))
        #expect(acc.step(MotionDelta(dx: 0, dy: 9)) == nil)
        #expect(acc.step(MotionDelta(dx: 2, dy: 0)) == ScrollTick(vertical: 0, horizontal: 2))
    }

    @Test func resetDropsTheCarry() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec(speed: 0.5))
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == nil)  // carry 0.5
        acc.reset()
        #expect(acc.step(MotionDelta(dx: 0, dy: 1)) == nil)  // would be 1.0 without reset
    }

    /// A trap in the tap callback takes the daemon down, so a hostile
    /// delta must saturate rather than crash.
    @Test func nonFiniteAndOverflowingDeltasCannotTrap() {
        var acc = DragScrollAccumulator(spec: DragScrollSpec())
        #expect(acc.step(MotionDelta(dx: .nan, dy: 1)) == nil)
        #expect(acc.step(MotionDelta(dx: 1, dy: .infinity)) == nil)
        let huge = acc.step(MotionDelta(dx: 1e30, dy: -1e30))
        #expect(huge == ScrollTick(vertical: .min, horizontal: .max))
    }

    // MARK: - parsing (accepted)

    @Test func minimalBindingParsesWithDefaults() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "drag"
            input = "mouse.side1"
            action-drag-scroll = true
            """)
        #expect(res.droppedBindings == 0)
        guard case .dragScroll(let spec) = res.config.bindings[0].action else {
            Issue.record("expected .dragScroll")
            return
        }
        #expect(spec.speed == DragScrollSpec.defaultSpeed)
        #expect(spec.axis == .both)
        #expect(spec.invert == false)
        #expect(spec.maxMs == DragScrollSpec.defaultMaxMs)
    }

    @Test func tuningSiblingsAreRead() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "drag"
            input = "cmd - j"
            action-drag-scroll = true
            action-drag-scroll-speed = 2.5
            action-drag-scroll-axis = "vertical"
            action-drag-scroll-invert = true
            action-drag-scroll-max-ms = 5000
            """)
        #expect(res.droppedBindings == 0)
        guard case .dragScroll(let spec) = res.config.bindings[0].action else {
            Issue.record("expected .dragScroll")
            return
        }
        #expect(spec.speed == 2.5)
        #expect(spec.axis == .vertical)
        #expect(spec.invert == true)
        #expect(spec.maxMs == 5000)
    }

    /// `speed = 2` (an int) has to be accepted as 2.0 — TOML distinguishes
    /// int from float and a user will not think about which they typed.
    @Test func integerSpeedIsAccepted() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "drag"
            input = "mouse.side1"
            action-drag-scroll = true
            action-drag-scroll-speed = 2
            """)
        #expect(res.droppedBindings == 0)
        guard case .dragScroll(let spec) = res.config.bindings[0].action else {
            Issue.record("expected .dragScroll")
            return
        }
        #expect(spec.speed == 2.0)
    }

    @Test func vkeyTriggerIsAccepted() throws {
        let res = try Config.parse(
            """
            [v-key-aliases]
            TU_LL_F = 0x1D

            [[bindings]]
            name = "drag"
            input = "TU_LL_F"
            action-drag-scroll = true
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.bindings[0].trigger == .vkey(0x1D))
    }

    /// A `[[fallbacks]]` wildcard is the one legal shape where the binding's
    /// trigger (`.anyKey`) is not the trigger the release arrives on — which
    /// is why the session is keyed by the EVENT's. Pinned here so the
    /// wildcard stays accepted at parse time.
    @Test func wildcardFallbackTriggerIsAccepted() throws {
        let res = try Config.parse(
            """
            [[fallbacks]]
            name = "any-drag"
            input = "*"
            action-drag-scroll = true
            """)
        #expect(res.droppedBindings == 0)
        #expect(res.config.fallbacks[0].trigger == .anyKey)
        guard case .dragScroll = res.config.fallbacks[0].action else {
            Issue.record("expected .dragScroll")
            return
        }
    }

    // MARK: - parsing (refusals)

    /// The mode's release half is implicit. An explicit `-on-up` spelling
    /// would be a second owner of the same edge, so it is refused rather
    /// than quietly dropped on the floor.
    @Test func onUpSpellingIsRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - x"
            action-keys = "cmd - c"
            action-drag-scroll-on-up = true
            """)
        #expect(res.config.bindings.isEmpty)
        #expect(
            res.warnings.contains {
                $0.kind == .dragScrollParseError && $0.message.contains("-on-up")
            })
    }

    @Test func nonTrueValueIsRejectedRatherThanIgnored() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - x"
            action-drag-scroll = false
            """)
        #expect(res.config.bindings.isEmpty)
        #expect(
            res.warnings.contains {
                $0.kind == .dragScrollParseError && $0.message.contains("must be true")
            })
    }

    @Test func combiningWithAnotherActionIsRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - x"
            action-drag-scroll = true
            action-shell = "echo hi"
            """)
        #expect(res.config.bindings.isEmpty)
        #expect(
            res.warnings.contains {
                $0.kind == .dragScrollParseError && $0.message.contains("mutually exclusive")
            })
    }

    /// The span, not just the press. An `action-*-on-up` fires off the very
    /// release edge that closes the mode — two owners of one edge, which is
    /// the same objection that rules out a second action on the down half.
    @Test func combiningWithAnOnUpActionIsRejected() throws {
        for key in ["action-keys-on-up = \"cmd - c\"", "action-shell-on-up = \"echo hi\""] {
            let res = try Config.parse(
                """
                [[bindings]]
                name = "bad"
                input = "cmd - x"
                action-drag-scroll = true
                \(key)
                """)
            #expect(res.config.bindings.isEmpty, "\(key) should drop the binding")
            #expect(
                res.warnings.contains {
                    $0.kind == .dragScrollParseError && $0.message.contains("mutually exclusive")
                })
        }
    }

    @Test func orphanTuningWithoutTheActionIsRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - x"
            action-keys = "cmd - c"
            action-drag-scroll-speed = 2.0
            """)
        #expect(res.config.bindings.isEmpty)
        #expect(
            res.warnings.contains {
                $0.kind == .dragScrollParseError
                    && $0.message.contains("without action-drag-scroll")
            })
    }

    @Test func outOfDomainTuningIsRejected() throws {
        for (field, value) in [
            ("action-drag-scroll-speed", "0"),
            ("action-drag-scroll-speed", "-1.0"),
            ("action-drag-scroll-axis", "\"diagonal\""),
            ("action-drag-scroll-invert", "\"yes\""),
            ("action-drag-scroll-max-ms", "0")
        ] {
            let res = try Config.parse(
                """
                [[bindings]]
                name = "bad"
                input = "cmd - x"
                action-drag-scroll = true
                \(field) = \(value)
                """)
            #expect(res.config.bindings.isEmpty, "\(field) = \(value) should drop the binding")
            #expect(res.warnings.contains { $0.kind == .dragScrollParseError })
        }
    }

    /// The mode is bounded by its own release. A trigger that has no
    /// paired release would pin the cursor until the watchdog with nothing
    /// the user could press to stop it — so it is refused at load.
    @Test func triggersWithoutAPairedReleaseAreRejected() throws {
        let scrollRes = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "scroll.up"
            action-drag-scroll = true
            """)
        #expect(scrollRes.config.bindings.isEmpty)
        #expect(
            scrollRes.warnings.contains {
                $0.kind == .dragScrollParseError && $0.message.contains("paired release")
            })

        let modsRes = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd + opt"
            action-drag-scroll = true
            """)
        #expect(modsRes.config.bindings.isEmpty)
        #expect(
            modsRes.warnings.contains {
                $0.kind == .dragScrollParseError && $0.message.contains("paired release")
            })
    }

    @Test func passthroughIsRejected() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "bad"
            input = "cmd - x"
            action-drag-scroll = true
            passthrough = true
            """)
        #expect(res.config.bindings.isEmpty)
        #expect(
            res.warnings.contains {
                $0.kind == .dragScrollParseError && $0.message.contains("passthrough")
            })
    }

    // MARK: - wire schema

    @Test func wireActionCarriesResolvedTuning() throws {
        let res = try Config.parse(
            """
            [[bindings]]
            name = "drag"
            input = "mouse.side1"
            action-drag-scroll = true
            action-drag-scroll-axis = "horizontal"
            action-drag-scroll-speed = 0.5
            """)
        let doc = BindingsSchema.makeDocument(from: res)
        let action = doc.bindings[0].action
        #expect(action.kind == "drag-scroll")
        // Defaults are resolved on the wire, so a consumer never has to
        // re-implement them.
        #expect(action.dragScroll?.speed == 0.5)
        #expect(action.dragScroll?.axis == "horizontal")
        #expect(action.dragScroll?.invert == false)
        #expect(action.dragScroll?.maxMs == DragScrollSpec.defaultMaxMs)
    }

    /// The wire format is snake_case throughout; `WireAction` had no
    /// explicit CodingKeys before this action, so a camelCase leak here
    /// would be easy to miss and impossible to fix later without a bump.
    @Test func wireActionUsesSnakeCaseForTheNestedObject() throws {
        let json = try parseToBindingsJSON(
            """
            [[bindings]]
            name = "drag"
            input = "mouse.side1"
            action-drag-scroll = true
            """)
        let bindings = try #require(json["bindings"] as? [[String: Any]])
        let action = try #require(bindings[0]["action"] as? [String: Any])
        #expect(action["dragScroll"] == nil, "camelCase must not leak onto the wire")
        let drag = try #require(action["drag_scroll"] as? [String: Any])
        #expect(drag["max_ms"] as? Int == DragScrollSpec.defaultMaxMs)
        #expect(drag["axis"] as? String == "both")
    }
}

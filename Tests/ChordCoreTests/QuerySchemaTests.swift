import XCTest
@testable import ChordCore

/// Exercises the `chord.query.v1` wire contract ([QuerySchema]) and the
/// recent-fires [RingBuffer] — pure data in / data out, no socket. The
/// socket transport itself is verified live (a running daemon is needed
/// to bind AF_UNIX); these lock the request grammar, the JSON shape /
/// key spelling, and the ring overflow semantics so they can't drift.
final class QuerySchemaTests: XCTestCase {

    // MARK: - endpoint vocabulary (wire tokens == CLI verb stems)

    func testEndpointRawValuesAreStable() {
        // These strings are the on-wire request tokens AND the CLI verb
        // stems (`--` + rawValue). A rename is a wire break.
        XCTAssertEqual(Set(QuerySchema.Endpoint.allCases.map(\.rawValue)),
                       ["status", "vars", "loaded-bindings", "recent-fires"])
    }

    // MARK: - request line round-trip

    func testRequestLineEncoding() {
        XCTAssertEqual(QuerySchema.Request(endpoint: .vars).line, "vars\n")
        XCTAssertEqual(QuerySchema.Request(endpoint: .recentFires, limit: 10).line,
                       "recent-fires 10\n")
        XCTAssertEqual(QuerySchema.Request(endpoint: .loadedBindings).line,
                       "loaded-bindings\n")
    }

    func testRequestLineParsing() {
        XCTAssertEqual(QuerySchema.Request(line: "status\n"),
                       QuerySchema.Request(endpoint: .status))
        XCTAssertEqual(QuerySchema.Request(line: "recent-fires 10\n"),
                       QuerySchema.Request(endpoint: .recentFires, limit: 10))
        XCTAssertEqual(QuerySchema.Request(line: "loaded-bindings\n")?.endpoint,
                       .loadedBindings)
        // tolerant of surrounding whitespace, no trailing newline
        XCTAssertEqual(QuerySchema.Request(line: "  vars  ")?.endpoint, .vars)
        XCTAssertNil(QuerySchema.Request(line: "  vars  ")?.limit)
    }

    func testRequestParsingRejectsBadInput() {
        XCTAssertNil(QuerySchema.Request(line: "bogus\n"))         // unknown endpoint
        XCTAssertNil(QuerySchema.Request(line: "\n"))              // empty
        XCTAssertNil(QuerySchema.Request(line: "recent-fires abc")) // non-int limit
        XCTAssertNil(QuerySchema.Request(line: "recent-fires -5"))  // negative
        XCTAssertNil(QuerySchema.Request(line: "recent-fires 0"))   // zero
        XCTAssertNil(QuerySchema.Request(line: "recent-fires 10 junk")) // trailing junk
        XCTAssertNil(QuerySchema.Request(line: "status extra"))         // verb takes no arg
    }

    func testRequestRoundTrips() {
        for ep in QuerySchema.Endpoint.allCases {
            let r = QuerySchema.Request(endpoint: ep, limit: ep == .recentFires ? 7 : nil)
            XCTAssertEqual(QuerySchema.Request(line: r.line), r, "round-trip \(ep)")
        }
    }

    // MARK: - response JSON shape (keys / spelling / version)

    /// Decode encoded JSON back to a key→value map for assertions.
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStatusResponseShape() throws {
        let data = QuerySchema.encode(QuerySchema.StatusResponse(
            queriedAt: "2026-06-16T00:00:00.000Z", paused: true, axGranted: false,
            version: "9.9.9", uptimeS: 42, configLoadedAt: "2026-06-16T00:00:00.000Z"))
        let o = try object(data)
        XCTAssertEqual(o["schema"] as? String, "chord.query.v1")
        XCTAssertEqual(o["endpoint"] as? String, "status")
        XCTAssertEqual(o["paused"] as? Bool, true)
        // snake_case spelling on the wire
        XCTAssertNotNil(o["ax_granted"])
        XCTAssertNotNil(o["uptime_s"])
        XCTAssertNotNil(o["config_loaded_at"])
        XCTAssertNotNil(o["queried_at"])
        XCTAssertEqual(o["version"] as? String, "9.9.9")
    }

    func testStatusOmitsConfigLoadedAtWhenNil() throws {
        let data = QuerySchema.encode(QuerySchema.StatusResponse(
            queriedAt: "t", paused: false, axGranted: true,
            version: "1", uptimeS: 0, configLoadedAt: nil))
        // nil-Optional fields are omitted (Codable default), not null.
        XCTAssertNil(try object(data)["config_loaded_at"])
    }

    func testVarsResponseShape() throws {
        let data = QuerySchema.encode(QuerySchema.VarsResponse(
            queriedAt: "t", vars: ["jlayer": 0, "ultra": 1]))
        let o = try object(data)
        XCTAssertEqual(o["endpoint"] as? String, "vars")
        let vars = try XCTUnwrap(o["vars"] as? [String: Int])
        XCTAssertEqual(vars["ultra"], 1)
        XCTAssertEqual(vars["jlayer"], 0)
    }

    func testLoadedBindingsResponseShape() throws {
        let data = QuerySchema.encode(QuerySchema.LoadedBindingsResponse(
            queriedAt: "t", bindings: 21, fallbacks: 4,
            actionAliases: 1, inputAliases: 4))
        let o = try object(data)
        XCTAssertEqual(o["endpoint"] as? String, "loaded-bindings")
        XCTAssertEqual(o["bindings"] as? Int, 21)
        XCTAssertEqual(o["fallbacks"] as? Int, 4)
        XCTAssertEqual(o["action_aliases"] as? Int, 1)
        XCTAssertEqual(o["input_aliases"] as? Int, 4)
    }

    func testRecentFiresResponseShape() throws {
        let fire = QuerySchema.FireRecord(
            ts: "2026-06-16T00:00:00.000Z", name: "tab-left",
            app: "com.apple.Safari", action: "keys")
        let data = QuerySchema.encode(QuerySchema.RecentFiresResponse(
            queriedAt: "t", fires: [fire]))
        let o = try object(data)
        XCTAssertEqual(o["endpoint"] as? String, "recent-fires")
        let fires = try XCTUnwrap(o["fires"] as? [[String: Any]])
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0]["name"] as? String, "tab-left")
        XCTAssertEqual(fires[0]["app"] as? String, "com.apple.Safari")
        XCTAssertEqual(fires[0]["action"] as? String, "keys")
        XCTAssertEqual(fires[0]["ts"] as? String, "2026-06-16T00:00:00.000Z")
    }

    func testErrorJSONShape() throws {
        let o = try object(QuerySchema.errorJSON("nope"))
        XCTAssertEqual(o["schema"] as? String, "chord.query.v1")
        XCTAssertEqual(o["error"] as? String, "nope")
    }

    // MARK: - RingBuffer

    func testRingBufferUnderCapacity() {
        var r = RingBuffer<Int>(capacity: 3)
        r.append(1); r.append(2)
        XCTAssertEqual(r.elements(), [1, 2])
        XCTAssertEqual(r.count, 2)
    }

    func testRingBufferAtCapacity() {
        var r = RingBuffer<Int>(capacity: 3)
        [1, 2, 3].forEach { r.append($0) }
        XCTAssertEqual(r.elements(), [1, 2, 3])
        XCTAssertEqual(r.count, 3)
    }

    func testRingBufferOverflowKeepsNewestInOrder() {
        var r = RingBuffer<Int>(capacity: 3)
        [1, 2, 3, 4].forEach { r.append($0) }
        XCTAssertEqual(r.elements(), [2, 3, 4])   // oldest (1) dropped
        [5, 6].forEach { r.append($0) }
        XCTAssertEqual(r.elements(), [4, 5, 6])
        XCTAssertEqual(r.count, 3)
    }

    func testRingBufferCapacityOne() {
        var r = RingBuffer<Int>(capacity: 1)
        r.append(1); r.append(2)
        XCTAssertEqual(r.elements(), [2])
    }
}

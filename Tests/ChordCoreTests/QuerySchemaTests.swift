import Foundation
import Testing
@testable import ChordCore

/// Exercises the `chord.query.v1` wire contract ([QuerySchema]) and the
/// recent-fires [RingBuffer] — pure data in / data out, no socket. The
/// socket transport itself is verified live (a running daemon is needed
/// to bind AF_UNIX); these lock the request grammar, the JSON shape /
/// key spelling, and the ring overflow semantics so they can't drift.
@Suite struct QuerySchemaTests {

    // MARK: - endpoint vocabulary (wire tokens == CLI verb stems)

    @Test func endpointRawValuesAreStable() {
        // These strings are the on-wire request tokens AND the CLI verb
        // stems (`--` + rawValue). A rename is a wire break.
        #expect(
            Set(QuerySchema.Endpoint.allCases.map(\.rawValue)) == [
                "status", "vars", "loaded-bindings", "recent-fires"
            ])
    }

    // MARK: - request line round-trip

    @Test func requestLineEncoding() {
        #expect(QuerySchema.Request(endpoint: .vars).line == "vars\n")
        #expect(QuerySchema.Request(endpoint: .recentFires, limit: 10).line == "recent-fires 10\n")
        #expect(QuerySchema.Request(endpoint: .loadedBindings).line == "loaded-bindings\n")
    }

    @Test func requestLineParsing() {
        #expect(QuerySchema.Request(line: "status\n") == QuerySchema.Request(endpoint: .status))
        #expect(
            QuerySchema.Request(line: "recent-fires 10\n")
                == QuerySchema.Request(endpoint: .recentFires, limit: 10))
        #expect(QuerySchema.Request(line: "loaded-bindings\n")?.endpoint == .loadedBindings)
        // tolerant of surrounding whitespace, no trailing newline
        #expect(QuerySchema.Request(line: "  vars  ")?.endpoint == .vars)
        #expect(QuerySchema.Request(line: "  vars  ")?.limit == nil)
    }

    @Test func requestParsingRejectsBadInput() {
        #expect(QuerySchema.Request(line: "bogus\n") == nil)  // unknown endpoint
        #expect(QuerySchema.Request(line: "\n") == nil)  // empty
        #expect(QuerySchema.Request(line: "recent-fires abc") == nil)  // non-int limit
        #expect(QuerySchema.Request(line: "recent-fires -5") == nil)  // negative
        #expect(QuerySchema.Request(line: "recent-fires 0") == nil)  // zero
        #expect(QuerySchema.Request(line: "recent-fires 10 junk") == nil)  // trailing junk
        #expect(QuerySchema.Request(line: "status extra") == nil)  // verb takes no arg
    }

    @Test func requestRoundTrips() {
        for ep in QuerySchema.Endpoint.allCases {
            let r = QuerySchema.Request(endpoint: ep, limit: ep == .recentFires ? 7 : nil)
            #expect(QuerySchema.Request(line: r.line) == r, "round-trip \(ep)")
        }
    }

    // MARK: - response JSON shape (keys / spelling / version)

    /// Decode encoded JSON back to a key→value map for assertions.
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func statusResponseShape() throws {
        let data = QuerySchema.encode(
            QuerySchema.StatusResponse(
                queriedAt: "2026-06-16T00:00:00.000Z", paused: true, axGranted: false,
                version: "9.9.9", uptimeS: 42, configLoadedAt: "2026-06-16T00:00:00.000Z"))
        let o = try object(data)
        #expect(o["schema"] as? String == "chord.query.v1")
        #expect(o["endpoint"] as? String == "status")
        #expect(o["paused"] as? Bool == true)
        // snake_case spelling on the wire
        #expect(o["ax_granted"] != nil)
        #expect(o["uptime_s"] != nil)
        #expect(o["config_loaded_at"] != nil)
        #expect(o["queried_at"] != nil)
        #expect(o["version"] as? String == "9.9.9")
    }

    @Test func statusOmitsConfigLoadedAtWhenNil() throws {
        let data = QuerySchema.encode(
            QuerySchema.StatusResponse(
                queriedAt: "t", paused: false, axGranted: true,
                version: "1", uptimeS: 0, configLoadedAt: nil))
        // nil-Optional fields are omitted (Codable default), not null.
        #expect(try object(data)["config_loaded_at"] == nil)
    }

    @Test func varsResponseShape() throws {
        let data = QuerySchema.encode(
            QuerySchema.VarsResponse(
                queriedAt: "t", vars: ["jlayer": 0, "ultra": 1]))
        let o = try object(data)
        #expect(o["endpoint"] as? String == "vars")
        let vars = try #require(o["vars"] as? [String: Int])
        #expect(vars["ultra"] == 1)
        #expect(vars["jlayer"] == 0)
    }

    @Test func loadedBindingsResponseShape() throws {
        let data = QuerySchema.encode(
            QuerySchema.LoadedBindingsResponse(
                queriedAt: "t", bindings: 21, fallbacks: 4,
                actionAliases: 1, inputAliases: 4))
        let o = try object(data)
        #expect(o["endpoint"] as? String == "loaded-bindings")
        #expect(o["bindings"] as? Int == 21)
        #expect(o["fallbacks"] as? Int == 4)
        #expect(o["action_aliases"] as? Int == 1)
        #expect(o["input_aliases"] as? Int == 4)
    }

    @Test func recentFiresResponseShape() throws {
        let fire = QuerySchema.FireRecord(
            ts: "2026-06-16T00:00:00.000Z", name: "tab-left",
            app: "com.apple.Safari", action: "keys")
        let data = QuerySchema.encode(
            QuerySchema.RecentFiresResponse(
                queriedAt: "t", fires: [fire]))
        let o = try object(data)
        #expect(o["endpoint"] as? String == "recent-fires")
        let fires = try #require(o["fires"] as? [[String: Any]])
        #expect(fires.count == 1)
        #expect(fires[0]["name"] as? String == "tab-left")
        #expect(fires[0]["app"] as? String == "com.apple.Safari")
        #expect(fires[0]["action"] as? String == "keys")
        #expect(fires[0]["ts"] as? String == "2026-06-16T00:00:00.000Z")
    }

    @Test func errorJSONShape() throws {
        let o = try object(QuerySchema.errorJSON("nope"))
        #expect(o["schema"] as? String == "chord.query.v1")
        #expect(o["error"] as? String == "nope")
    }

    // MARK: - RingBuffer

    @Test func ringBufferUnderCapacity() {
        var r = RingBuffer<Int>(capacity: 3)
        r.append(1); r.append(2)
        #expect(r.elements() == [1, 2])
        #expect(r.count == 2)
    }

    @Test func ringBufferAtCapacity() {
        var r = RingBuffer<Int>(capacity: 3)
        [1, 2, 3].forEach { r.append($0) }
        #expect(r.elements() == [1, 2, 3])
        #expect(r.count == 3)
    }

    @Test func ringBufferOverflowKeepsNewestInOrder() {
        var r = RingBuffer<Int>(capacity: 3)
        [1, 2, 3, 4].forEach { r.append($0) }
        #expect(r.elements() == [2, 3, 4])  // oldest (1) dropped
        [5, 6].forEach { r.append($0) }
        #expect(r.elements() == [4, 5, 6])
        #expect(r.count == 3)
    }

    @Test func ringBufferCapacityOne() {
        var r = RingBuffer<Int>(capacity: 1)
        r.append(1); r.append(2)
        #expect(r.elements() == [2])
    }
}

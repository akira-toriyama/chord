import Foundation

/// Wire format for `chord query --…`, versioned `chord.query.v1`.
///
/// DISTINCT from `chord.bindings.v3` ([BindingsSchema]): that schema is
/// the *config parse-OUTPUT* (static, derived from config.toml). This
/// one is the daemon's *live runtime* state — current state-variable
/// values, the loaded-binding counts, the recent-fires history — read
/// over the query socket.
///
/// ## Transport
///
/// An AF_UNIX request/response socket at [socketPath]. The client writes
/// one request line (`"<endpoint> [limit]\n"`) and the daemon replies
/// with one JSON document, then closes. This is the read-only,
/// request/response complement to the two existing IPC shapes:
///   * DNC control (`daemon --reload` / `--quit` / `--pause`) is
///     write-only / fire-and-forget — it can't carry a reply.
///   * the `/tmp/chord.status` file is the reverse channel for the
///     single scalar status line that `daemon --show` reads — it can't
///     carry structured / dynamic state (live vars keyed by name, a
///     history ring).
/// Structured runtime reads genuinely need request/response, which is
/// what this socket provides. See chord's CLAUDE.md §IPC.
///
/// Output is always JSON: the `query` domain exists to export machine
/// state to external tools (tmux status bars, shell prompts, scripts),
/// so there is no separate human rendering and no `--json` modifier.
public enum QuerySchema {

    /// Wire-protocol version. Independent of [BindingsSchema.version]
    /// (`chord.bindings.v3`) — a different contract for a different
    /// payload (live state vs. parsed config).
    public static let version = "chord.query.v1"

    /// AF_UNIX request/response socket. Sibling of `/tmp/chord.status`
    /// (the control reverse-channel) and `/tmp/chord-loaded.json` (the
    /// config snapshot). The daemon (re)creates it on start and unlinks
    /// it on quit; a connect failure (no file, or no listener after a
    /// crash) is the client's "no daemon running" signal.
    public static let socketPath = "/tmp/chord-query.sock"

    /// ISO-8601 UTC with fractional seconds — same shape as
    /// `chord.bindings.v3`'s `generated_at`. Informational, not a
    /// stable sort key.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - request

    /// The read endpoints. `rawValue` is the on-wire token AND the CLI
    /// verb stem (`--` + rawValue), so the two never drift.
    public enum Endpoint: String, Sendable, CaseIterable {
        case status
        case vars
        case loadedBindings = "loaded-bindings"
        case recentFires    = "recent-fires"
    }

    /// One query. `limit` is only meaningful for `.recentFires` (the
    /// CLI rejects it on the other verbs); it caps the number of
    /// most-recent records returned.
    public struct Request: Sendable, Equatable {
        public let endpoint: Endpoint
        public let limit: Int?

        public init(endpoint: Endpoint, limit: Int? = nil) {
            self.endpoint = endpoint
            self.limit = limit
        }

        /// The newline-terminated line the client sends:
        /// `"recent-fires 10\n"`, `"vars\n"`.
        public var line: String {
            if let limit { return "\(endpoint.rawValue) \(limit)\n" }
            return "\(endpoint.rawValue)\n"
        }

        /// Parse a request line (daemon side). Tolerant of surrounding
        /// whitespace. A second token, if present, is a positive-int
        /// limit. Returns nil for an unknown endpoint or a malformed
        /// limit (so a raw `nc` typo gets a clean error, not a crash).
        public init?(line: String) {
            let parts = line.split(whereSeparator: {
                $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
            })
            // Strict grammar: `<endpoint>` or `<endpoint> <limit>`. Reject
            // trailing junk rather than silently ignoring it.
            guard parts.count >= 1, parts.count <= 2,
                  let ep = Endpoint(rawValue: String(parts[0])) else { return nil }
            var lim: Int? = nil
            if parts.count == 2 {
                guard let n = Int(parts[1]), n > 0 else { return nil }
                lim = n
            }
            self.init(endpoint: ep, limit: lim)
        }
    }

    // MARK: - response payloads
    //
    // Each endpoint is its own top-level document so consumers read the
    // payload at the top level (`jq .vars.jlayer`, `jq .paused`,
    // `jq '.fires[0]'`) rather than under a generic `data` wrapper. All
    // carry the `schema` / `queried_at` / `endpoint` header. snake_case
    // on the wire (CodingKeys), matching `chord.bindings.v3`.

    /// One fired-binding record (newest first in [RecentFiresResponse]).
    public struct FireRecord: Codable, Sendable, Equatable {
        /// ISO-8601 timestamp of the fire.
        public let ts: String
        /// The binding's name.
        public let name: String
        /// Frontmost app bundle id at fire time, absent if unknown.
        public let app: String?
        /// Compact action kind (`keys` / `shell` / `set-variable` …).
        public let action: String

        public init(ts: String, name: String, app: String?, action: String) {
            self.ts = ts; self.name = name; self.app = app; self.action = action
        }
    }

    public struct StatusResponse: Codable, Sendable {
        public let schema: String
        public let queriedAt: String
        public let endpoint: String
        public let paused: Bool
        public let axGranted: Bool
        public let version: String
        public let uptimeS: Int
        public let configLoadedAt: String?

        public init(queriedAt: String, paused: Bool, axGranted: Bool,
                    version: String, uptimeS: Int, configLoadedAt: String?) {
            self.schema = QuerySchema.version
            self.queriedAt = queriedAt
            self.endpoint = Endpoint.status.rawValue
            self.paused = paused
            self.axGranted = axGranted
            self.version = version
            self.uptimeS = uptimeS
            self.configLoadedAt = configLoadedAt
        }

        enum CodingKeys: String, CodingKey {
            case schema, endpoint, paused, version
            case queriedAt      = "queried_at"
            case axGranted      = "ax_granted"
            case uptimeS        = "uptime_s"
            case configLoadedAt = "config_loaded_at"
        }
    }

    public struct VarsResponse: Codable, Sendable {
        public let schema: String
        public let queriedAt: String
        public let endpoint: String
        public let vars: [String: Int]

        public init(queriedAt: String, vars: [String: Int]) {
            self.schema = QuerySchema.version
            self.queriedAt = queriedAt
            self.endpoint = Endpoint.vars.rawValue
            self.vars = vars
        }

        enum CodingKeys: String, CodingKey {
            case schema, endpoint, vars
            case queriedAt = "queried_at"
        }
    }

    public struct LoadedBindingsResponse: Codable, Sendable {
        public let schema: String
        public let queriedAt: String
        public let endpoint: String
        public let bindings: Int
        public let fallbacks: Int
        public let actionAliases: Int
        public let inputAliases: Int

        public init(queriedAt: String, bindings: Int, fallbacks: Int,
                    actionAliases: Int, inputAliases: Int) {
            self.schema = QuerySchema.version
            self.queriedAt = queriedAt
            self.endpoint = Endpoint.loadedBindings.rawValue
            self.bindings = bindings
            self.fallbacks = fallbacks
            self.actionAliases = actionAliases
            self.inputAliases = inputAliases
        }

        enum CodingKeys: String, CodingKey {
            case schema, endpoint, bindings, fallbacks
            case queriedAt     = "queried_at"
            case actionAliases = "action_aliases"
            case inputAliases  = "input_aliases"
        }
    }

    public struct RecentFiresResponse: Codable, Sendable {
        public let schema: String
        public let queriedAt: String
        public let endpoint: String
        public let fires: [FireRecord]

        public init(queriedAt: String, fires: [FireRecord]) {
            self.schema = QuerySchema.version
            self.queriedAt = queriedAt
            self.endpoint = Endpoint.recentFires.rawValue
            self.fires = fires
        }

        enum CodingKeys: String, CodingKey {
            case schema, endpoint, fires
            case queriedAt = "queried_at"
        }
    }

    /// Emitted for a malformed request (e.g. a raw `nc` typo). The
    /// chord CLI never triggers this — it only sends validated verbs.
    public struct ErrorResponse: Codable, Sendable {
        public let schema: String
        public let error: String
        public init(error: String) {
            self.schema = QuerySchema.version
            self.error = error
        }
    }

    // MARK: - encode

    /// Deterministic JSON for any response document. Same encoder
    /// settings as [BindingsSchema.encodeJSON] (sorted keys, pretty,
    /// unescaped slashes). No trailing newline — the server appends one.
    public static func encode<T: Encodable>(_ document: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        return (try? encoder.encode(document)) ?? Data("{}".utf8)
    }

    /// JSON error document for a malformed request.
    public static func errorJSON(_ message: String) -> Data {
        encode(ErrorResponse(error: message))
    }
}

/// Fixed-capacity ring of the most recent N elements. Overwrites the
/// oldest once full. Used for the daemon's recent-fires history; kept
/// pure (and in ChordCore) so the overflow behaviour is unit-testable.
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest element once `storage.count == capacity`.
    private var head = 0

    public init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Elements in chronological order (oldest → newest).
    public func elements() -> [Element] {
        guard storage.count == capacity else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }
}

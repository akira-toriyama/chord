import Foundation

/// Hand-rolled TOML subset parser. Ported from stroke's
/// `parseTOMLSubset` (which is itself extended from facet's). Same
/// `~100-line parser` budget — extending it must be justified by a
/// real config need.
///
/// Supported:
///   • `key = value` at table scope
///   • dotted keys (`a.b.c = …`) collapse to nested tables
///   • `[table]` headers
///   • `[[array-of-tables]]` headers
///   • values: string (`"…"` and `'…'`), int, float, bool, array
///     of those
///   • `#` comments through end of line
///
/// NOT supported (by design):
///   • inline tables `{ a = 1, b = 2 }`
///   • multi-line strings
///   • date / time literals
///   • nested arrays of arrays
///
/// All keys are emitted as `String` and all leaf values as one of
/// `String | Int64 | Double | Bool | [Any]`. Out-of-range parsing
/// is *strict* here — the clamping/defaults policy lives in
/// `Config.parse`, so a typo's blast radius stays one binding.
public enum TOML {
    public enum Value: Sendable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case array([Value])
        case table([String: Value])
        indirect case arrayOfTables([[String: Value]])
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    public static func parse(_ source: String) throws -> [String: Value] {
        var lines = source.split(separator: "\n",
                                 omittingEmptySubsequences: false)
                          .map(String.init).enumerated().makeIterator()
        var root: [String: Value] = [:]
        var currentPath: [String] = []
        // `currentArray` carries the in-progress `[[a.b]]` row when
        // active; otherwise nil and we write straight into a nested
        // table at `currentPath`.
        var inArrayOfTables = false

        while let (idx, raw) = lines.next() {
            let lineNo = idx + 1
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else {
                    throw ParseError(line: lineNo,
                                     message: "unterminated [[...]] header")
                }
                let path = line.dropFirst(2).dropLast(2)
                    .trimmingCharacters(in: .whitespaces)
                currentPath = path.split(separator: ".").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                appendArrayOfTablesRow(&root, path: currentPath,
                                       lineNo: lineNo)
                inArrayOfTables = true
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError(line: lineNo,
                                     message: "unterminated [...] header")
                }
                let path = line.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespaces)
                currentPath = path.split(separator: ".").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                inArrayOfTables = false
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                throw ParseError(line: lineNo,
                                 message: "expected '=' in '\(line)'")
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            let value = try parseValue(rhs, lineNo: lineNo)
            let dotted = key.split(separator: ".").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if inArrayOfTables {
                writeIntoArrayOfTablesRow(&root,
                                          path: currentPath,
                                          key: dotted,
                                          value: value)
            } else {
                let fullPath = currentPath + dotted
                write(&root, path: fullPath, value: value)
            }
        }

        return root
    }

    // MARK: - helpers

    private static func stripComment(_ s: String) -> String {
        var inString = false
        var quote: Character = "\""
        var out: [Character] = []
        for c in s {
            if inString {
                if c == quote { inString = false }
                out.append(c)
            } else if c == "\"" || c == "'" {
                inString = true
                quote = c
                out.append(c)
            } else if c == "#" {
                break
            } else {
                out.append(c)
            }
        }
        return String(out)
    }

    private static func parseValue(_ raw: String, lineNo: Int) throws -> Value {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return .string(unquote(raw))
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true"  { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else {
                throw ParseError(line: lineNo,
                                 message: "unterminated array")
            }
            let inner = String(raw.dropFirst().dropLast())
            let items = splitArray(inner)
            return .array(try items.map { try parseValue($0, lineNo: lineNo) })
        }
        if let i = Int64(raw) { return .int(i) }
        if let d = Double(raw) { return .double(d) }
        throw ParseError(line: lineNo, message: "unrecognised value '\(raw)'")
    }

    private static func unquote(_ raw: String) -> String {
        var s = String(raw.dropFirst().dropLast())
        // Minimal escape handling — enough for shell commands.
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
        s = s.replacingOccurrences(of: "\\\\", with: "\\")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\t", with: "\t")
        return s
    }

    private static func splitArray(_ raw: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var inStr = false
        var quote: Character = "\""
        var current = ""
        for c in raw {
            if inStr {
                current.append(c)
                if c == quote { inStr = false }
            } else if c == "\"" || c == "'" {
                inStr = true; quote = c; current.append(c)
            } else if c == "[" {
                depth += 1; current.append(c)
            } else if c == "]" {
                depth -= 1; current.append(c)
            } else if c == "," && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            } else {
                current.append(c)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }

    private static func write(_ root: inout [String: Value],
                              path: [String], value: Value) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            root[path[0]] = value
            return
        }
        var inner: [String: Value]
        if case .table(let t) = root[path[0]] { inner = t }
        else { inner = [:] }
        var sub = inner
        writeInner(&sub, path: Array(path.dropFirst()), value: value)
        root[path[0]] = .table(sub)
    }

    private static func writeInner(_ table: inout [String: Value],
                                   path: [String], value: Value) {
        if path.count == 1 {
            table[path[0]] = value
            return
        }
        var inner: [String: Value]
        if case .table(let t) = table[path[0]] { inner = t } else { inner = [:] }
        writeInner(&inner, path: Array(path.dropFirst()), value: value)
        table[path[0]] = .table(inner)
    }

    /// Synthetic key injected into each [[X]] row so downstream code
    /// (notably Config.makeBinding) can attribute warnings to a real
    /// line number. Users who name a real TOML key `__line__` would
    /// shadow it — acceptable trade-off; the alternative is changing
    /// the return type to carry sidecar metadata.
    static let lineKey = "__line__"

    private static func appendArrayOfTablesRow(_ root: inout [String: Value],
                                               path: [String],
                                               lineNo: Int) {
        guard !path.isEmpty else { return }
        let seed: [String: Value] = [lineKey: .int(Int64(lineNo))]
        if path.count == 1 {
            var rows: [[String: Value]]
            if case .arrayOfTables(let existing) = root[path[0]] {
                rows = existing
            } else { rows = [] }
            rows.append(seed)
            root[path[0]] = .arrayOfTables(rows)
            return
        }
        var inner: [String: Value]
        if case .table(let t) = root[path[0]] { inner = t } else { inner = [:] }
        appendArrayOfTablesRowInner(&inner,
                                    path: Array(path.dropFirst()),
                                    lineNo: lineNo)
        root[path[0]] = .table(inner)
    }

    private static func appendArrayOfTablesRowInner(
        _ table: inout [String: Value], path: [String], lineNo: Int
    ) {
        let seed: [String: Value] = [lineKey: .int(Int64(lineNo))]
        if path.count == 1 {
            var rows: [[String: Value]]
            if case .arrayOfTables(let existing) = table[path[0]] {
                rows = existing
            } else { rows = [] }
            rows.append(seed)
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        var inner: [String: Value]
        if case .table(let t) = table[path[0]] { inner = t } else { inner = [:] }
        appendArrayOfTablesRowInner(&inner,
                                    path: Array(path.dropFirst()),
                                    lineNo: lineNo)
        table[path[0]] = .table(inner)
    }

    private static func writeIntoArrayOfTablesRow(
        _ root: inout [String: Value], path: [String],
        key: [String], value: Value
    ) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            guard case .arrayOfTables(var rows) = root[path[0]],
                  !rows.isEmpty
            else { return }
            var row = rows[rows.count - 1]
            writeInner(&row, path: key, value: value)
            rows[rows.count - 1] = row
            root[path[0]] = .arrayOfTables(rows)
            return
        }
        guard case .table(var inner) = root[path[0]] else { return }
        writeIntoArrayOfTablesRowInner(&inner,
                                       path: Array(path.dropFirst()),
                                       key: key, value: value)
        root[path[0]] = .table(inner)
    }

    private static func writeIntoArrayOfTablesRowInner(
        _ table: inout [String: Value], path: [String],
        key: [String], value: Value
    ) {
        if path.count == 1 {
            guard case .arrayOfTables(var rows) = table[path[0]],
                  !rows.isEmpty
            else { return }
            var row = rows[rows.count - 1]
            writeInner(&row, path: key, value: value)
            rows[rows.count - 1] = row
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        guard case .table(var inner) = table[path[0]] else { return }
        writeIntoArrayOfTablesRowInner(&inner,
                                       path: Array(path.dropFirst()),
                                       key: key, value: value)
        table[path[0]] = .table(inner)
    }
}

// Convenience accessors used by Config.parse.
public extension TOML.Value {
    var asString: String? { if case .string(let s) = self { return s }; return nil }
    var asInt: Int64?     { if case .int(let i)    = self { return i }; return nil }
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var asBool: Bool?     { if case .bool(let b)   = self { return b }; return nil }
    var asArray: [TOML.Value]? {
        if case .array(let a) = self { return a }; return nil
    }
    var asTable: [String: TOML.Value]? {
        if case .table(let t) = self { return t }; return nil
    }
    var asArrayOfTables: [[String: TOML.Value]]? {
        if case .arrayOfTables(let rows) = self { return rows }; return nil
    }
}

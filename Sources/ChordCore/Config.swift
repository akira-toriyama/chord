import Foundation

/// Parses TOML → [ChordConfig]. Out-of-range / unknown values are
/// *clamped* or *dropped* with a warning rather than rejected — a
/// typo in one binding can never disable the whole daemon. The
/// strict-rejection path is `chord --validate`, which surfaces
/// every warning and fails with a non-zero exit if any binding
/// dropped.
public enum Config {
    public struct ParseResult: Sendable {
        public var config: ChordConfig
        public var warnings: [String]
        public var droppedBindings: Int
    }

    public enum LoadError: Error, CustomStringConvertible {
        case ioError(String)
        case tomlError(String)
        public var description: String {
            switch self {
            case .ioError(let m): return m
            case .tomlError(let m): return m
            }
        }
    }

    /// Read + parse the file at [ChordConfig.path]. A missing file
    /// is *not* an error: returns an empty config. (The README
    /// tells users to `curl` the template into place; an empty
    /// daemon is a perfectly reasonable startup state.)
    public static func load(path: String = ChordConfig.path) throws
        -> ParseResult
    {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return ParseResult(config: .init(),
                               warnings: ["config not found at \(path)"],
                               droppedBindings: 0)
        }
        let source: String
        do { source = try String(contentsOf: url, encoding: .utf8) }
        catch { throw LoadError.ioError("read \(path): \(error)") }
        return try parse(source)
    }

    public static func parse(_ source: String) throws -> ParseResult {
        let root: [String: TOML.Value]
        do { root = try TOML.parse(source) }
        catch let e as TOML.ParseError { throw LoadError.tomlError(String(describing: e)) }
        catch { throw LoadError.tomlError(String(describing: error)) }

        var warnings: [String] = []
        var options = ChordConfig.Options()

        if case .table(let opts)? = root["options"] {
            if let b = opts["passthrough-unmatched"]?.asBool {
                options.passthroughUnmatched = b
            }
            if let arr = opts["exclude-apps"]?.asArray {
                options.excludeApps = arr.compactMap(\.asString)
            }
        }

        var bindings: [Binding] = []
        var dropped = 0
        let rows = root["bindings"]?.asArrayOfTables ?? []
        for (i, row) in rows.enumerated() {
            do {
                if let b = try makeBinding(from: row, index: i,
                                           warnings: &warnings)
                {
                    bindings.append(b)
                } else {
                    dropped += 1
                }
            } catch {
                dropped += 1
                warnings.append(
                    "[[bindings]] #\(i + 1): \(error) — dropped")
            }
        }

        let cfg = ChordConfig(options: options, bindings: bindings)
        return ParseResult(config: cfg, warnings: warnings,
                           droppedBindings: dropped)
    }

    private static func makeBinding(
        from row: [String: TOML.Value], index: Int,
        warnings: inout [String]
    ) throws -> Binding? {
        let name = row["name"]?.asString ?? "binding-\(index + 1)"
        guard let inputRaw = row["input"]?.asString else {
            warnings.append("[[bindings]] '\(name)': missing 'input'")
            return nil
        }
        let parsed: InputParser.Parsed
        do { parsed = try InputParser.parse(inputRaw) }
        catch {
            warnings.append("[[bindings]] '\(name)': \(error)")
            return nil
        }

        let action: Action
        if let shell = row["action-shell"]?.asString {
            action = .shell(shell)
        } else if let keysStr = row["action-keys"]?.asString {
            do {
                let (mods, code) =
                    try InputParser.parseKeyForOutput(keysStr)
                action = .keys(mods, code)
            } catch {
                warnings.append(
                    "[[bindings]] '\(name)': action-keys: \(error)")
                return nil
            }
        } else if row["action-noop"]?.asBool == true {
            action = .noop
        } else {
            warnings.append(
                "[[bindings]] '\(name)': no action-* key provided")
            return nil
        }

        var apps: [String]?
        if let arr = row["apps"]?.asArray {
            let strs = arr.compactMap(\.asString)
            apps = strs.isEmpty || strs == ["*"] ? nil : strs
        }

        return Binding(name: name, trigger: parsed.trigger,
                       modifiers: parsed.modifiers, apps: apps,
                       action: action)
    }
}

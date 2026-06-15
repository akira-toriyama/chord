import Foundation

/// `[[sequence]]` sugar extraction (chord 0.7.0+).
///
/// Lives in its own file so the next sequence-related feature
/// (e.g. nested sequences, per-app sequences) doesn't push
/// `Config.swift` further past its already-painful size. The
/// public `Config` enum stays the single import surface — this
/// file only adds a static helper method called by `Config.parse`.
///
/// Decomposition rationale: see Issue #51 (split Config.swift).
extension Config {

    /// Result of expanding the `[[sequence]]` section:
    ///   • `expanded`  — prefix + child bindings in document order
    ///                   (per-sequence, prefix first then its children).
    ///   • `prefixes`  — just the prefix bindings, used by the main
    ///                   loop to detect collisions with regular
    ///                   `[[bindings]]` rows.
    ///   • `dropped`   — count of malformed sequences / children for
    ///                   the `config --validate --strict` exit code.
    struct SequenceParse {
        var expanded: [Binding]
        var prefixes: [Binding]
        var dropped: Int
    }

    /// Expand `[[sequence]]` rows into ordinary Binding values.
    /// Pure syntactic sugar over v2 state-var:
    ///   * the prefix becomes `action-set-var = "_seq_<name>"` with
    ///     `hold-while-timeout = <timeout-ms>`
    ///   * each child becomes a binding gated by `when-var = "_seq_<name>"`,
    ///     with its `input` composed as `"<prefix-modset> - <child input>"`
    /// Matcher / Controller see only the resulting bindings; there is
    /// no runtime concept of "sequence".
    ///
    /// Per the v0.7.0 issue, narrow surface intentionally:
    ///   * `timeout-ms` is required (the `hold-while` lifecycle does
    ///     not survive atomic ZMK chords, so the alternative would
    ///     defeat the leader-key use case)
    ///   * the prefix must include at least one modifier (a bare-key
    ///     leader would swallow every primary press)
    ///   * children's `input` are primary-only — they inherit the
    ///     prefix's modset
    ///   * nested `[[sequence.sequence]]` is rejected (out of scope)
    static func parseSequences(
        root: [String: TOML.Value],
        actionAliases: [String: String],
        inputAliases: [String: Modifiers],
        warnings: inout [ConfigWarning]
    ) -> SequenceParse {
        var expanded: [Binding] = []
        var prefixes: [Binding] = []
        var dropped = 0
        var seenNames: Set<String> = []

        let rows = root["sequence"]?.asArrayOfTables ?? []
        for (i, row) in rows.enumerated() {
            let line = row[TOML.lineKey]?.asInt.map { Int($0) }
            let source = sourceTag(line: line)
            let rawName = row["name"]?.asString
            let seqName = rawName ?? "sequence-\(i + 1)"

            func failSeq(_ msg: String) {
                warnings.append(ConfigWarning(
                    kind: .sequenceParseError,
                    message: "[[sequence]] '\(seqName)'\(source): \(msg)",
                    sourceLine: line, bindingName: seqName))
                dropped += 1
            }

            // Reject `name = "_seq_..."` — the name maps directly to
            // the synthetic variable `_seq_<name>`, and `_seq_` is
            // the reservation surface we enforce on user `action-set-var`.
            if let n = rawName, n.hasPrefix("_seq_") {
                failSeq("sequence name must not start with '_seq_' (reserved)")
                continue
            }

            if seenNames.contains(seqName) {
                failSeq("duplicate sequence name (each sequence " +
                        "owns variable '_seq_\(seqName)' — names " +
                        "must be unique)")
                continue
            }
            seenNames.insert(seqName)

            if row["sequence"] != nil {
                failSeq("nested [[sequence.sequence]] is not supported")
                continue
            }

            guard let prefixRaw = row["prefix"]?.asString else {
                failSeq("missing 'prefix'")
                continue
            }
            guard let timeoutRaw = row["timeout-ms"]?.asInt else {
                failSeq("missing or non-integer 'timeout-ms'")
                continue
            }
            let timeoutMs = Int(timeoutRaw)
            guard timeoutMs > 0 else {
                failSeq("timeout-ms must be > 0 (got \(timeoutMs))")
                continue
            }

            // Verify the prefix parses and has at least one modifier.
            let prefixParsed: InputParser.Parsed
            do {
                prefixParsed = try InputParser.parse(
                    prefixRaw,
                    allowWildcard: false,
                    inputAliases: inputAliases)
            } catch {
                failSeq("prefix: \(error)")
                continue
            }
            guard prefixParsed.modifiers.rawValue != 0 else {
                failSeq("prefix must include at least one modifier " +
                        "(a bare-key leader would swallow every press)")
                continue
            }

            // Extract the modset substring from the prefix raw. The
            // InputParser splits on the first `-` whenever the whole
            // string isn't itself a primary token — since we just
            // verified prefixParsed.modifiers is non-empty, that branch
            // ran and the first `-` IS the separator.
            let trimmedPrefix = prefixRaw.trimmingCharacters(in: .whitespaces)
            guard let dashIdx = trimmedPrefix.firstIndex(of: "-") else {
                failSeq("internal error: prefix parsed with modifiers but no separator")
                continue
            }
            let modsetStr = String(trimmedPrefix[..<dashIdx])
                .trimmingCharacters(in: .whitespaces)

            let childRows = row["bindings"]?.asArrayOfTables ?? []
            guard !childRows.isEmpty else {
                failSeq("no [[sequence.bindings]] children declared")
                continue
            }

            let varName = "_seq_\(seqName)"

            // Prefix binding — synthesize a row and reuse makeBinding so
            // all the v2 validation (hold-while-timeout positive, etc.)
            // runs uniformly. allowReservedVarNames bypasses the
            // `_seq_*` guard for this synthetic row only.
            var prefixRow: [String: TOML.Value] = [
                "name": .string("\(seqName) [enter]"),
                "input": .string(prefixRaw),
                "action-set-var": .string(varName),
                "hold-while-timeout": .int(Int64(timeoutMs)),
            ]
            if let lv = row[TOML.lineKey] { prefixRow[TOML.lineKey] = lv }
            guard let prefixBinding = makeBinding(
                from: prefixRow, index: i, isFallback: false,
                actionAliases: actionAliases,
                inputAliases: inputAliases,
                allowReservedVarNames: true,
                warnings: &warnings)
            else {
                // makeBinding already appended its own warning.
                dropped += 1
                continue
            }
            expanded.append(prefixBinding)
            prefixes.append(prefixBinding)

            // Child bindings.
            for (ci, child) in childRows.enumerated() {
                let childLine = child[TOML.lineKey]?.asInt.map { Int($0) } ?? line
                let childSrc = sourceTag(line: childLine)
                let childName = child["name"]?.asString
                    ?? "\(seqName).\(ci + 1)"

                guard let childInputRaw = child["input"]?.asString else {
                    warnings.append(ConfigWarning(
                        kind: .missingInput,
                        message:
                            "[[sequence.bindings]] '\(childName)'\(childSrc): " +
                            "missing 'input'",
                        sourceLine: childLine, bindingName: childName))
                    dropped += 1
                    continue
                }

                // Compose: prefix modset + " - " + child primary.
                // Children are primary-only by design (issue spec) —
                // if the user wrote their own modifier prefix, the
                // composed string will fail to parse and makeBinding
                // surfaces a clear "unknown-input-token" warning.
                let composedInput = "\(modsetStr) - \(childInputRaw)"
                var childRow = child
                childRow["name"] = .string(childName)
                childRow["input"] = .string(composedInput)
                childRow["when-var"] = .string(varName)
                if childRow[TOML.lineKey] == nil,
                   let lv = row[TOML.lineKey] {
                    childRow[TOML.lineKey] = lv
                }

                if let b = makeBinding(
                    from: childRow, index: ci, isFallback: false,
                    actionAliases: actionAliases,
                    inputAliases: inputAliases,
                    allowReservedVarNames: true,
                    warnings: &warnings)
                {
                    expanded.append(b)
                } else {
                    dropped += 1
                }
            }
        }

        return SequenceParse(expanded: expanded, prefixes: prefixes,
                             dropped: dropped)
    }
}

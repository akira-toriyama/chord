// Config+Alias.swift — #51 split of Config.swift.
// `@name` / `@name(args)` alias resolution with `{{N}}` substitution
// (resolveAlias is internal — `parseAction` calls it across files).
// Members of `enum Config`.

import Foundation

extension Config {
    // internal: `resolveAlias` returns this and `parseAction`
    // (Config+Action.swift) switches over its cases across the file boundary.
    enum AliasResolution {
        /// Either no `@name` was used (`aliasName == nil`) or it
        /// resolved successfully (`aliasName == "rift_focus_next"`).
        case body(String, aliasName: String?)
        case undefined(String)
        /// chord 0.9.0+: `@name(args)` call-site error — alias body
        /// has `{{N}}` placeholder but the call doesn't supply enough
        /// args, or the parenthesised arg list is malformed.
        case callError(aliasName: String, message: String)
    }

    /// Resolve a single `@name` or `@name(arg1, arg2, …)` token at
    /// the start of the value against [actionAliases]. Anything else
    /// is passed through unchanged.
    ///
    /// `@name(args)` (chord 0.9.0+) parses parenthesised arguments and
    /// substitutes them into `{{1}}` `{{2}}` … placeholders in the
    /// alias body. The substitution is **literal** (no shell escape):
    /// the user is expected to add their own quoting in the alias body
    /// (e.g. `afplay "{{1}}.wav"`). This matches the issue example and
    /// keeps the implementation small; tighter escape semantics can be
    /// added later if needed.
    ///
    /// `@name` (no parens) still works for unparameterised aliases.
    /// Mixing — a body with `{{N}}` but the call site uses bare
    /// `@name`, or vice versa — surfaces a structured `.callError`.
    static func resolveAlias(
        _ raw: String,
        actionAliases: [String: String]
    )
        -> AliasResolution
    {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return .body(raw, aliasName: nil) }

        // Read the identifier after `@` up to either '(' or end /
        // whitespace. The identifier charset is the same as before:
        // letter / digit / underscore / hyphen.
        let afterAt = trimmed.dropFirst()
        var nameEnd = afterAt.startIndex
        while nameEnd < afterAt.endIndex {
            let c = afterAt[nameEnd]
            if c.isLetter || c.isNumber || c == "_" || c == "-" {
                nameEnd = afterAt.index(after: nameEnd)
            } else {
                break
            }
        }
        let name = String(afterAt[..<nameEnd])
        if name.isEmpty {
            return .body(raw, aliasName: nil)
        }
        let rest = String(afterAt[nameEnd...])

        // Bare `@name` (no parens): existing v1 path.
        if rest.isEmpty {
            return resolveBareAlias(name: name, actionAliases: actionAliases)
        }
        // `@name(...)` call form.
        if rest.hasPrefix("(") {
            // The closing paren must terminate the value (no trailing
            // junk like `@name() trailing`); else fall through to
            // literal so the user's `@name(typo` doesn't silently
            // become a partial alias call.
            guard rest.hasSuffix(")") else {
                return .body(raw, aliasName: nil)
            }
            let inner = String(rest.dropFirst().dropLast())
            let args = parseAliasCallArgs(inner)
            return resolveCallAlias(
                name: name, args: args,
                actionAliases: actionAliases)
        }
        // `@name arg` (no parens, trailing text). Treat as literal —
        // the v1 spec carve-out, kept so users with whitespace-quoted
        // shell shorthand don't suddenly hit an alias error.
        return .body(raw, aliasName: nil)
    }

    /// Bare `@name` resolution — looks the alias body up in
    /// `actionAliases` (the `@name(args)` call form goes through
    /// `resolveCallAlias` instead).
    private static func resolveBareAlias(
        name: String,
        actionAliases: [String: String]
    ) -> AliasResolution {
        guard let body = actionAliases[name] else {
            return .undefined(name)
        }
        // Body has `{{N}}` but the user called bare? Reject — running
        // the body verbatim would leak `{{N}}` into the shell.
        let needed = maxPlaceholder(in: body)
        if needed > 0 {
            return .callError(
                aliasName: name,
                message:
                    "alias '\(name)' uses {{1}}..{{\(needed)}} "
                    + "placeholders — call it as @\(name)(arg, …) " + "with arguments")
        }
        return .body(body, aliasName: name)
    }

    private static func resolveCallAlias(
        name: String, args: [String],
        actionAliases: [String: String]
    ) -> AliasResolution {
        guard let body = actionAliases[name] else {
            return .undefined(name)
        }
        let needed = maxPlaceholder(in: body)
        if needed > args.count {
            return .callError(
                aliasName: name,
                message:
                    "alias '\(name)' needs {{\(needed)}} but only "
                    + "\(args.count) argument(s) supplied at call site")
        }
        // Substitute {{1}}…{{N}} in the body. Literal substitution —
        // see resolveAlias docstring for the escape contract.
        var substituted = body
        for i in (1...max(needed, 1)).reversed() {
            // Reverse order so that `{{10}}` (if ever supported) isn't
            // accidentally hit by the `{{1}}` pass. Currently single-
            // digit only but cheap to be defensive.
            guard i <= args.count else { continue }
            substituted = substituted.replacingOccurrences(
                of: "{{\(i)}}", with: args[i - 1])
        }
        return .body(substituted, aliasName: name)
    }

    /// Walk an alias body and return the highest `{{N}}` placeholder
    /// number (1-based). Returns 0 when no placeholder is present.
    /// Limited to single-digit N to keep the scan trivial — chord's
    /// shell-action surface never needs more than a handful of args.
    private static func maxPlaceholder(in body: String) -> Int {
        var maxN = 0
        let chars = Array(body)
        var i = 0
        while i + 4 < chars.count {
            if chars[i] == "{" && chars[i + 1] == "{",
                let d = chars[i + 2].wholeNumberValue,
                chars[i + 3] == "}", chars[i + 4] == "}",
                d > 0
            {
                if d > maxN { maxN = d }
                i += 5
                continue
            }
            i += 1
        }
        return maxN
    }

    /// Split the inside of `@name(...)` on commas, respecting double
    /// and single quotes. Bare args are trimmed; quoted args have
    /// the surrounding quotes stripped (contents kept verbatim).
    /// Empty input → empty args list. Whitespace-only segments drop.
    private static func parseAliasCallArgs(_ inner: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inStr = false
        var quote: Character = "\""
        for c in inner {
            if inStr {
                if c == quote { inStr = false } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                inStr = true
                quote = c
            } else if c == "," {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty || !out.isEmpty {
                    out.append(trimmed)
                }
                current = ""
            } else {
                current.append(c)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty || !out.isEmpty {
            out.append(trimmed)
        }
        return out
    }
}

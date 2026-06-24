#!/usr/bin/env bash
# check-warning-kind-sync.sh — assert ConfigWarning.Kind raw values stay in
# sync across the 3 places that must never drift. Run in CI (build.yml) BEFORE
# the expensive build; sibling of check-version-sync.sh.
#
# Why this exists: canon makes renaming a ConfigWarning.Kind raw value (or any
# dropped.kind schema enum value) a schema MAJOR bump — the value is part of
# the consumer-facing wire contract. The three copies were honor-system; this
# makes drift fatal. The compiled-enum counterpart is
# Tests/ChordCoreTests/ConfigWarningKindSyncTests.swift (CaseIterable is the
# authority) — ship both: this script fails fast pre-build with no toolchain,
# the test cross-checks via the real enum.
#
# The 3 places:
#   1. Swift enum  — Sources/ChordCore/ConfigWarning.swift   (enum Kind: String)
#   2. wire schema — docs/schema/chord.bindings.v3.json       ($defs.dropped.properties.kind.enum)
#   3. glossary    — docs/glossary.md                         (### ConfigWarning.Kind table)
#
# NOTE: this is the OUTPUT wire schema (chord.bindings.v3.json), NOT the INPUT
# config.schema.json (that drift is guarded by ConfigSchemaDriftTests).

set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 - <<'PY'
import json, re, sys, pathlib

root = pathlib.Path('.')

# 1. Swift enum raw values, scoped to the `enum Kind: String { … }` block so a
#    future unrelated string enum in the same file can't pollute the set.
swift_src = (root / 'Sources/ChordCore/ConfigWarning.swift').read_text()
block = re.search(r'enum Kind\s*:\s*String[^{]*\{(.*?)\n    \}', swift_src, re.S)
if not block:
    print('error: could not locate `enum Kind: String { … }` in ConfigWarning.swift', file=sys.stderr)
    sys.exit(1)
swift = set(re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', block.group(1)))

# 2. wire-schema dropped.kind enum.
schema = json.loads((root / 'docs/schema/chord.bindings.v3.json').read_text())
try:
    wire = set(schema['$defs']['dropped']['properties']['kind']['enum'])
except (KeyError, TypeError):
    print('error: $defs.dropped.properties.kind.enum missing from chord.bindings.v3.json', file=sys.stderr)
    sys.exit(1)

# 3. glossary `### ConfigWarning.Kind` table — backtick-quoted values up to the
#    next heading / horizontal rule.
gloss_src = (root / 'docs/glossary.md').read_text()
section = re.search(r'###\s+`?ConfigWarning\.Kind`?\s*\n(.*?)(?:\n#{2,3}\s|\n---\s)', gloss_src, re.S)
if not section:
    print('error: could not locate `### ConfigWarning.Kind` section in glossary.md', file=sys.stderr)
    sys.exit(1)
gloss = set(re.findall(r'`"([^"]+)"`', section.group(1)))

places = {'swift-enum': swift, 'wire-schema': wire, 'glossary': gloss}
union = set().union(*places.values())
drift = {name: sorted(union - vals) for name, vals in places.items() if vals != union}

if drift:
    print('ConfigWarning.Kind DRIFT across the 3-place contract:', file=sys.stderr)
    for name, missing in drift.items():
        print(f'  {name} is MISSING: {missing}', file=sys.stderr)
    print('', file=sys.stderr)
    print('fix: a ConfigWarning.Kind raw value must appear in all 3 — the Swift', file=sys.stderr)
    print('enum, docs/schema/chord.bindings.v3.json (dropped.kind enum), and', file=sys.stderr)
    print('docs/glossary.md (### ConfigWarning.Kind). Per canon a *rename* of an', file=sys.stderr)
    print('existing value is a schema MAJOR bump; adding a new value is additive.', file=sys.stderr)
    sys.exit(1)

print(f'ConfigWarning.Kind sync OK: {len(union)} kinds across swift-enum / wire-schema / glossary')
PY

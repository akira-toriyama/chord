<!--
Title: gitmoji-driven — <:gitmoji:>[(<scope>)][!] <subject>, where the leading
:code: IS the type (see https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md,
machine source of truth `glyph rules`):
  :sparkles:(core) add hyper modifier sugar

If this is a single-commit PR, squashing into main will use the
commit message as the PR title — keep them in sync.
-->

## What this changes
<!-- one paragraph for humans -->

## Why
<!-- the constraint, bug, or feature request driving it -->

## Test plan

- [ ] `swift build` clean
- [ ] `swift test` green
- [ ] `chord config --validate` on a config that exercises the change
- [ ] (if user-facing) updated `README.md`
- [ ] (if a new constraint) added a "Non-obvious constraints" line in `CLAUDE.md`

## Glossary / non-goals review

- [ ] this code change introduces no new domain term (if it does,
      [docs/glossary.md](../blob/main/docs/glossary.md) is updated **in the
      same PR**)
- [ ] no existing term is renamed or changes meaning (if one does,
      `docs/glossary.md` is synced and the old name is added to the entry's
      **`Don't call it:`** field)
- [ ] no schema enum value (`docs/glossary.md` §3 /
      `docs/schema/chord.bindings.v3.json`) is renamed (if one is, a
      **v4 schema bump** discussion is filed)
- [ ] no [docs/non-goals.md](../blob/main/docs/non-goals.md) non-goal is
      implemented unintentionally (if one is, non-goals.md is updated as its
      "When this becomes Yes" condition being met)

## Notes for reviewers
<!-- anything subtle: re-entrancy, lock window, layer crossing, … -->

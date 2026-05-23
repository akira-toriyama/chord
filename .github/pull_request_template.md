<!--
Title: gitmoji + Conventional Commits (see docs/commit-convention.md):
  :sparkles: feat(core): add hyper modifier sugar

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
- [ ] `chord --validate` on a config that exercises the change
- [ ] (if user-facing) updated `README.md` AND `README.ja.md`
- [ ] (if a new constraint) added a "Non-obvious constraints" line in `CLAUDE.md`

## Notes for reviewers
<!-- anything subtle: re-entrancy, lock window, layer crossing, … -->

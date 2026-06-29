<!--
Title: gitmoji + Conventional Commits (see https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md):
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
- [ ] `chord config --validate` on a config that exercises the change
- [ ] (if user-facing) updated `README.md` AND `README.ja.md`
- [ ] (if a new constraint) added a "Non-obvious constraints" line in `CLAUDE.md`

## Glossary / non-goals review

- [ ] このコード変更で新規 domain term を導入していない (した場合は
      [docs/glossary.md](../blob/main/docs/glossary.md) を **同 PR で** 更新済)
- [ ] 既存の term を rename / 意味変更していない (した場合は
      `docs/glossary.md` を同期、旧名は entry の **`Don't call it:`** 欄へ追加済)
- [ ] schema enum 値 (`docs/glossary.md` §3 / `docs/schema/chord.bindings.v3.json`)
      の rename を含まない (含む場合は **v4 schema bump** 議論を起票済)
- [ ] [docs/non-goals.md](../blob/main/docs/non-goals.md) の non-goal を
      意図せず実装していない (実装した場合は non-goals.md 側を「When this
      becomes Yes」条件達成として更新)

## Notes for reviewers
<!-- anything subtle: re-entrancy, lock window, layer crossing, … -->

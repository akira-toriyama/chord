# Commit convention

chord uses **gitmoji + Conventional Commits**:

```
<:gitmoji:> <type>(<scope>)<!>: <subject>
```

`(<scope>)` and the breaking-change `!` are optional. `<subject>`
is the imperative present (`add`, `fix`, not `added`, `fixes`).
Wrap the body at 72 columns; the title at 72 too.

## Types

Same set as facet / stroke — CI (`commit-lint.yml`) enforces them.

| type      | gitmoji                  | use for                                      |
|-----------|--------------------------|----------------------------------------------|
| feat      | `:sparkles:`             | user-visible new capability                  |
| fix       | `:bug:`                  | user-visible bug fix                         |
| docs      | `:memo:`                 | docs / comments only                         |
| test      | `:test_tube:`            | adding or refactoring tests                  |
| refactor  | `:recycle:`              | code change with no behaviour change         |
| perf      | `:zap:`                  | observable performance win                   |
| build     | `:hammer:` / `:wrench:`  | build script / Package.swift / CI            |
| ci        | `:construction_worker:`  | `.github/workflows/` only                    |
| chore     | `:rocket:` / `:rotating_light:` | tidy-ups, dep bumps, formatting       |
| revert    | `:rewind:`               | revert a previous commit                     |
| style     | `:art:`                  | whitespace / formatting only                 |

## Scopes (suggested)

`core`, `adapter`, `app`, `cli`, `config`, `docs`, `ci`, `tests`,
`packaging`. New scopes are fine — keep them lowercase, one word.

## Examples

```
:sparkles: feat(core): support hyper modifier sugar in InputParser
:bug: fix(adapter): re-enable tap after tapDisabledByTimeout
:memo: docs(readme): document F21–F24 keycode convention
:test_tube: test(core): cover ! exclusion glob in MatcherTests
:recycle: refactor(app): collapse Controller.handle's matcher snapshot
```

## Breaking changes

Add `!` after the type/scope:

```
:boom: feat(core)!: rename action-keys → action-keystrokes
```

…and explain the migration in the commit body.

## Local hook

```sh
git config core.hooksPath scripts/hooks
```

The hook validates the message format before each commit.

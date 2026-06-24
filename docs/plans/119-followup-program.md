# post-policy follow-up program

- Issue: Refs #119 (umbrella). Spun-out: #120 schema / #121 docs / #122 refactor / #123 observe / #124 feature-discuss / #125 consolidation
- Status: in-progress
- Updated: 2026-06-24

## ゴール

maintainer から受けた 4 領域 (リファクタ / docs 整理 / 共通化 / 機能調査) を、
品質重視・破壊的変更可・セッション跨ぎ前提で消化する。read-only 調査 workflow
(17 agents) の所見を本 file に集約し、安全で価値の高い順に PR 化する。全項目が
完了 (= 各 issue close か明示的に skip 判断) したら本 file を削除し #119 を close。

調査 raw 出力: workflow `chord-followup-investigation` (18 refactor / 27 doc /
10 consolidation findings + 29 feature candidates、agents_failed=0)。

## 1. schema↔code contract (#120) — fix, HIGH

`config --validate/--show --json` 出力が docs/schema/chord.bindings.v3.json に
対し validation 不成立だった 3 件。コード読みで confirmed。

- [x] parsed_counts: `WireParsedCounts` に CodingKeys 追加 (`actionAliases` → `action_aliases`)。Schema.swift:107-111
- [x] dropped[].section: Schema.swift:677 `[actionAliases]`→`[action-aliases]` (casing bug) + doc comment 277。v3.json section enum に `[v-key-aliases]` 追加 (forward-compatible)
- [x] dropped[].kind: v3.json kind enum に `v-key-alias-invalid` 追加 (唯一の欠落、forward-compatible)
- ルール: Schema.swift と v3.json は同一 commit。enum 追加は major bump 不要。
- ✅ done in this PR (#120)。

## 2. docs staleness sweep (#121) — docs, HIGH/MED

VariableStore/StateScheduler refactor + 0.9.0 機能で旧記述が残存。**本 PR の方針
記録 (CLAUDE.md 作業方針節) とは無関係な既存 drift。**

- [ ] CLAUDE.md state-machine 節 (276-342): store は ChordCore `VariableStore`
  (NSLock 内蔵) + 注入 `StateScheduler`。`stateSnapshot()`/`applyVariable()`/
  `stateLock`/`clearStaleVariables`/`timerFired` 等の symbol 名要更新 (※コード照合してから書く)
- [ ] CLAUDE.md 310-313「single-variable equality only (no a==1 && b==2)」誤り →
  `when-vars` conjunction が 0.9.0 出荷済 (OR/NOT・nested は依然なし)。`action-toggle-var` 追記
- [ ] CLAUDE.md References>TOML (856-861) 自己矛盾解消 (swift-toml-edit 委譲・inline table 可)。CGEventTap eventMask に keyUp/*MouseUp 追記 (797-798)
- [ ] glossary §1 Action table (toggleVariable 欠/5 cases)、§2 passthrough 許可 action、§4 state-var の Controller.variables 参照 (gone→VariableStore)、§5 v-key edge (VKeyEdgeTracker へ) + autorepeat (#29 計画でなく 0.9.0 出荷済)
- [ ] README.ja.md に `chord query` domain 丸ごと追加 (EN canonical)。両 README に `config --emit-schema` 追記
- [ ] architecture.md: ChordCore CoreGraphics import 許可 (実態は未使用)、Adapter module box ファイル数。Version.swift / Package.swift doc comment stale (D0 hazard / Info.plist.dev)
- [ ] (redundancy) ConfigWarning.Kind raw 値が glossary §3 / schema enum / code の 3 箇所 → canonical を ConfigWarning.swift とし drift 防止 (CI check 検討)

## 3. refactor / comment sweep (#122) — refactor, 大半 low/S

bug ではないが誤読を招く comment↔code mismatch + dead code + 低リスク重複。

- [ ] comment↔code mismatch: Controller B-α timer conjunction 非対応 (165-171)・'Strong'→weak (39)、ActionDispatcher postKeys (56-74)、Models actionAliases doc (args 0.9.0 出荷)、Config.swift 警告文 `[actionAliases]`
- [ ] stale-comment: Controller snapshot (67-71)、Main `--list`→`--show` (464)、Schema header v1/v2-era、ConfigWarning no-op bump 例、Matcher class doc 誤配置
- [ ] dead-code: Log.emit `mirrorToStderrOverride` 引数 (全 caller nil)、resolveBareAlias `body` 引数、cmdToggle 到達不能 branch (Main 277-279)
- [ ] 低リスク重複: sockaddr_un setup (QueryServer/Control)、JSONEncoder 構築 (Schema/QuerySchema)、action-interception switch (handle/fireBindingAction)

## 4. feature: chord observe (#123) — adopt 候補 (要設計判断)

interactive keycode/modifier/mouse discovery (skhd `-o`)。survey 唯一の adopt。
AX のみ・headless debugging 補強・consume/pass 単段契約に非抵触。

- [ ] 維持者確認: verb 配置 (`config --observe` vs top-level `chord observe`) / 出力 format
- [ ] 実装 (確認後)

## 5. feature-survey discuss (#124) — 維持者判断待ち

macro timing (fits) / when-window-title (fits, Adapter 機構増) / per-key leader timing /
repeat-last-action (fits) / mouse_key (one-shot に scope) / to_delayed_action (#22/#23 に畳む) /
.shell interpreter (lean skip)。skip 21 件は USP/non-goal/既存 issue と重複で除外済。

- [ ] 維持者がどれを issue 化/着手するか選定

## 6. consolidation (#125) — 大半 defer/discuss

- taplo reusable + config.toml `#:schema`: **既に対応済** (no-op)
- [ ] (actionable) glossary.yml thin caller 追加 (Pages 公開。要 Pages 有効化確認)
- [ ] (decision) dependabot #116 sill 1.12.0: merge or `@dependabot ignore` major (low-value、未 link の SwiftDraw transitive)
- [ ] (decision/cross-repo) swift-toml-edit source-span API PR → chord の `__line__` plumbing 削除。interim: Config.swift:90 dead guard 修正のみ可
- [ ] (defer) sill ConfigSchema 拡張 (#52 icebox、2+ app bar 要確認) / verb-dispatch helper (facet CLIKit 移行待ち) / taplo fmt --check 中央化

## 進行ログ

- 2026-06-24: 方針記録 PR #118 merge (#117 close)。調査 workflow 完了 (17 agents)。
  所見を 6 issue (#120-#125) + 本 plan に集約。schema contract 3 件をコード照合で confirmed → #120 着手。
  doc/refactor は mechanical だが量があるため別 PR で順次。feature/consolidation の decision 項目は維持者に提示。

## 未達成・保留 (明示)

- #121 docs sweep / #122 refactor sweep: 着手前 (mechanical、PR 順次)。
- #123 observe / #124 feature 群 / #125 の decision 項目: 維持者の判断待ち (黙って進めない)。
- 運用メモ: plan file 更新は repo が PR 必須のため、各 work PR 内で該当 checkbox を同時更新する運用とする (plan 専用 PR を毎回作らない)。これで運用しづらければ相談。

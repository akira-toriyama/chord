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

- [x] CLAUDE.md state-machine 節: store は ChordCore `VariableStore` (NSLock 内蔵) + 注入 `StateScheduler` ("chord.state.timer")。`snapshot()`/`set()`/`toggle()`/`clearStale()`/`reset()` に更新
- [x] CLAUDE.md「single-variable equality only」誤り修正 → equality OR `when-vars` conjunction (0.9.0)。`action-toggle-var` 追記
- [x] CLAUDE.md References>TOML 自己矛盾解消 (swift-toml-edit 委譲)。CGEventTap eventMask に keyUp/*MouseUp 追記
- [x] glossary §1 Action (toggleVariable 追加)/Binding fields、§2 passthrough、§4 state-var→VariableStore、§5 v-key edge→VKeyEdgeTracker + autorepeat 出荷済
- [x] README.ja.md に `chord query` domain 追加 (EN sync)。両 README に `config --emit-schema`。VS Code 表記統一
- [x] architecture.md: CoreGraphics import 許可削除、Adapter box は代表 subset と注記 + 全7ファイル列挙。Version.swift / Package.swift doc comment 修正
- [x] source doc-comment staleness (Schema header v3 / Models @name(args) / Matcher class-doc 配置 / ConfigWarning / Controller "Strong"→Weak・snapshot・B-α narrow / Main --show / Config 警告文 `[action-aliases]`)
- [ ] (redundancy, 残) ConfigWarning.Kind raw 値が glossary §3 / schema enum / code の 3 箇所 → drift 防止の CI check は別途検討 (#125 寄り)
- ✅ done in PR (#121)。**#122 の comment-text 項目も本 sweep で吸収済**。

## 3. refactor sweep (#122) — code change のみ (comment-text 項目は #121 で吸収済)

comment↔code mismatch / stale-comment は #121 PR で対応済。残りは **実コード変更**:

- [ ] dead-code 削除: Log.emit `mirrorToStderrOverride` 引数 (全 caller nil)、resolveBareAlias `body` 引数、cmdToggle 到達不能 branch (Main 277-279)
- [ ] 低リスク重複 (任意・要 behavior-equivalence 確認): sockaddr_un setup (QueryServer/Control)、JSONEncoder 構築 (Schema/QuerySchema)、action-interception switch (handle/fireBindingAction)
- 注: B-α comment は #121 で「single .variable」に narrow 済 (code は据え置き)。コードを conjunction 対応にするかは別判断 (低優先)。

## 4. feature: chord observe (#123) — adopt 候補 (要設計判断)

interactive keycode/modifier/mouse discovery (skhd `-o`)。survey 唯一の adopt。
AX のみ・headless debugging 補強・consume/pass 単段契約に非抵触。

- [x] 維持者確認 → **`config --observe` で実装** (config domain、--doctor/--emit-schema と同 family)
- [ ] 実装: configVerbs に `--observe` 追加 / 短命 CGEventTap を passthrough で開き keyDown code+mods(side bits)+mouse/scroll を stderr に stream / Ctrl-C 終了 / 自前 AX grant を help に注記 / テスト

## 5. feature-survey discuss (#124) — 維持者判断待ち

macro timing (fits) / when-window-title (fits, Adapter 機構増) / per-key leader timing /
repeat-last-action (fits) / mouse_key (one-shot に scope) / to_delayed_action (#22/#23 に畳む) /
.shell interpreter (lean skip)。skip 21 件は USP/non-goal/既存 issue と重複で除外済。

- [ ] 維持者がどれを issue 化/着手するか選定

## 6. consolidation (#125) — 大半 defer/discuss

- taplo reusable + config.toml `#:schema`: **既に対応済** (no-op)
- [x] dependabot #116 sill 1.12.0: **merge 判断** (auto-merge 設定済、CI 緑で merge)
- [ ] (actionable) glossary.yml thin caller 追加 (Pages 公開。要 Pages 有効化確認) ← 維持者「推奨/一貫性 fix OK」
- [ ] (cross-repo, 保留) swift-toml-edit source-span API PR → chord の `__line__` plumbing 削除。interim: Config.swift:90 dead guard 修正のみ可
- [ ] (defer) sill ConfigSchema 拡張 (#52 icebox、2+ app bar 要確認) / verb-dispatch helper (facet CLIKit 移行待ち) / taplo fmt --check 中央化

## 進行ログ

- 2026-06-24: 方針記録 PR #118 merge (#117 close)。調査 workflow 完了 (17 agents)。
  所見を 6 issue (#120-#125) + 本 plan に集約。
- 2026-06-24: #120 schema contract fix → PR #126 merge。dependabot #116 (sill 1.12.0) auto-merge 設定。
  維持者 decision: observe=`config --observe`、#116=merge、共通化=推奨/一貫性 fix OK。
- 2026-06-24: #121 docs sweep (14 files、doc+comment text のみ・build 緑) → PR #121。#122 の comment 項目を吸収。

## 未達成・保留 (明示)

- **#122 refactor**: dead-code 削除 (Log.emit/resolveBareAlias/cmdToggle) + 任意の dedup。次の PR。
- **#123 observe**: `config --observe` 実装 (決定済、未着手)。
- **glossary.yml Pages publisher** (#125): 追加予定 (要 Pages 有効化確認)。
- **#124 feature 群**: 維持者がどれを issue 化するか待ち (parked、黙って進めない)。
- **cross-repo (保留)**: swift-toml-edit span API / sill ConfigSchema(#52) — heavier、別途相談。
- 運用メモ: plan file 更新は各 work PR 内で該当 checkbox を同時更新 (plan 専用 PR を作らない)。

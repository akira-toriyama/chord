# config.toml オーサリング補助 (Taplo/schema) 強化

- Issue: Closes #138 (umbrella)。Sub: #144 A / #145 B / #146 C / #147 D / #148 E
- Status: in-progress (Phase A ✅ / Phase B ✅ 実装完了・PR 中 / C・D・E 残)
- Updated: 2026-06-24

## ゴール

GUI なし family の中で chord の `config.toml` は最も複雑。**エディタ補助
(JSON Schema + Taplo) が事実上の UX** = config.toml は UI と言っても過言ではない。
徹底調査 → 設計確定 → **直列 PR(1 本ずつ merge)**で品質最優先に強化する。

**maintainer 方針 (2026-06-24)**: 他アプリも続く前提で **先行投資 OK**・
**sill / swift-toml-edit / 関連リポへの Push / PR / マージ OK**・破壊的変更 OK・
**全体の品質最優先(時間はかけてよい)**・進行を記録しながら進める。

## 徹底調査の結論 (workflow `chord-138-config-authoring-investigation`, 13 agents, 2026-06-24)

### 確定事実

- INPUT config schema は `Sources/ChordCore/ConfigSchema/` の **データのみ descriptor**
  `ChordConfigSchema` が単一 SoT。`config --emit-schema` (SchemaEmit) と parser の
  unknown-key check (StructuralCheck) の **両方**を駆動 → drift しない。emit 先は
  `config.schema.json` (1270行、`#:schema` 紐付け済)。**OUTPUT wire schema
  (`chord.bindings.v3.json`) とは別物 — 本件は INPUT 側のみ、wire 契約に触れない**。
- 現状: `description` 131 / `examples` 24 / cross-field ExclusionRule は Draft-07 lowering 済。
  **`markdownDescription` 0 / `x-*` 0 / `$ref` 0 / leaf-DSL の `pattern` 0**。
- **調査が当初前提を訂正**: `markdownDescription` は **taplo では死に setting**
  (taplo は標準 `description` を Markdown 描画。markdownDescription は taplo の VS Code 拡張専用)。
  → 実効は **`x-taplo.docs.enumValues`**(enum 値ごとの hover)+ **`initKeys`**(補完 pre-fill)
  + **examples を description に畳む**(taplo は JSON-Schema `examples` を hover に出さない)。
- sill `ConfigSchema` (316行): Field に examples typing / markdownDescription / x-taplo carrier 無し・
  cross-field rule primitive 無し。**facet は採用済 (45 description fields)**、chord は自前 descriptor
  (sill の flat-table decode に乗れない + keySet/rejected 責務が sill に無い)。

### 設計論点1 の決着: chord-LOCAL 主体 + cross-repo 共有層整備(先行投資)

- chord は **sill ConfigSchema に乗れない (収束は非対称)** → 寄せる方向は「chord の語彙を上げる」のみ。
- 2+ app bar: per-field richness は満たす(facet + chord)。cross-field primitive は当初未達だったが
  **「他アプリも続く前提」で先行投資 OK** → generic primitive を sill に抽出する (#147)。
  chord-state 固有(set/toggle/hold-var triad)と descriptor/keySet は local 据え置き。

## 直列 PR 計画 (risk-monotonic・各 phase 独立 shippable・1 PR ずつ merge)

### Phase A (#144, low) — CI drift-guard (schema 形状不変) ✅ DONE (chord#149 / perch#136 / wand#165 / .github#7)

- [x] A1: emit-parity drift-guard → **既存 `ConfigSchemaDriftTests` で担保済**と判明。冗長な build.yml step は不採用(どちらもビルド済バイナリ要・fast-fail 優位なし)。
- [x] A2: `scripts/check-warning-kind-sync.sh`(pre-build fast fail)+ `ConfigWarningKindSyncTests`(compiled-enum 権威)。Swift 23 == v3.json 23 == glossary §302。← chord#149 merged。
- [x] A3: 共有 `.github` taplo.yml に `taplo fmt --check`(family-wide)。caller=chord/facet/perch/wand/sill のみと実測。perch#136 / wand#165 正規化 merge → .github#7 flip → 5 caller workflow_dispatch 全 green 検証。pin 0.7.0 で fmt --check 動作確認(bump 不要)。

### Phase B (#145, low) — chord-local x-taplo editor-UX uplift (descriptor+emitter のみ) ✅ 実装完了

- [x] B1: `enumDocs` → `x-taplo.docs.enumValues`(action-mission-control/action-screenshot/repeat、index 整合)。
- [x] B2: `initKeys`(binding=[input,action-keys]、sequence=[prefix,timeout-ms])。※ `initKeys`(≠ initFields)。
- [x] B3: markdownDescription は出さない。**examples を全廃 → `description` に畳む**(SchemaEmit から examples emission 削除 + SchemaField.examples 撤去)。array-example-as-string 欠陥は構造的に解消。
- [x] B4: `x-chord-constraints` で 7 ルールを hover 可視化。**A方式採用**(maintainer 意見一致): `runtimeConstraints` catalog(kind タグ付)→ emit。`ConfigConstraintCoverageTests` で全 ConfigWarning.Kind を分類(surfaced/notSurfaced)し silent escape 防止。
- [x] B5: `config.schema.json` 再生成(1323行)/ keySet 不変(drift-guard + shape test 通過)/ `swift test` 393 green / taplo lint clean。

### Phase C (#146, med) — sill per-field richness push (先行投資・ship)

- [ ] C: sill `ConfigSchema.Field` に typed `examples:[DefaultValue]?` + `markdownDescription:String?` を
      additive 追加(全 nil default → facet byte 一致)。backward-compat byte-identity test。v1.25.0。

### Phase D (#147, med-high) — generic cross-field lowering を sill へ抽出

- [ ] D: forbidsTogether/dependency/oneOf/anyOf の lowering helper を sill に抽出 → chord emitter が呼ぶ。
      chord-state 固有 triad と keySet は local。ChordCore に `import ConfigSchema` 増(pure・層規則 OK)。
      behavior-equivalence(emit byte 一致)を test 担保。

### Phase E (#148, med) — swift-toml-edit native source-span API

- [ ] E: swift-toml-edit に source-span/location API 追加 → chord の `__line__` plumbing 撤去 →
      `config --validate` error を行・列精密化。最低優先・直列の最後。

## validation hardening の整理 (品質の核)

- **既に schema enforce 済 (confirm のみ)**: action-* anyOf / hold-while ⊕ hold-while-timeout /
  when-var ⊕ when-vars / set/toggle/hold-var triad / action-set-value ⇒ action-set-var / input ⊕ inputs。
- **x-chord-constraints で可視化のみ (Draft-07 で enforce 不能)**: undefined @name/$name/v-key alias /
  duplicate-binding-name / duplicate-sequence-name / binding↔sequence-prefix 衝突 / v-key を remap-key・
  sequence-child に使用 / alias が modifier/v-key 名 shadow。enforce は daemon/`config --validate`。
- **意図的に runtime-only (pattern 足さない)**: input/action-keys/hold-while/modifiers/sequence-prefix。
- **訂正**: `_seq_*` を schema 化するなら `not:{pattern:^_seq_}`。`^(?!_seq_)` lookahead は taplo の
  RE2 系で compile 不能 → schema 全体 hard-fail。現状 runtime のまま。
- **Phase A の contract-integrity guard が最大の validation win**。

## 進行ログ

- 2026-06-24: #119/#125 close + 残タスク整理 (#142 Icebox / #143 Backlog)。#138 に cross-repo 吸収。
- 2026-06-24: investigation workflow 完了 (13 agents)。論点1 決着。markdownDescription が taplo で死にと判明。
- 2026-06-24: maintainer 判断 — 5-phase 全部 (A→E)・先行投資 OK・cross-repo PR/merge OK・family-wide taplo・
  品質最優先。#138 umbrella + #144-148 に分解、board 反映。Phase A 着手。
- 2026-06-24: **Phase A 完了** — chord#149(ConfigWarning.Kind 3-place guard)merge。A3 family-wide:
  perch#136 / wand#165 正規化 → .github#7(`taplo fmt --check`)flip → 5 caller 全 green 検証。#144 close。
  ※ wand ローカル checkout が origin から乖離していたため fresh clone(SSH)で作業(教訓: sibling 直 push 注意)。
- 2026-06-24: **Phase B 実装完了** — descriptor に enumDocs/initKeys/xChordConstraints 追加・examples 全廃 →
  description 畳み込み。emitter に x-taplo.docs.enumValues / x-taplo.initKeys / x-chord-constraints。
  catalog(A方式・kind タグ付)+ ConfigConstraintCoverageTests。config.schema.json 再生成(1323行)。
  393 tests green / taplo lint clean。PR 準備中。

## 未達成・保留 (明示)

- **Phase C (#146)**: sill per-field richness push(typed examples + markdownDescription、v1.25.0)。次。
- **Phase D (#147)**: generic cross-field lowering を sill へ抽出。
- **Phase E (#148)**: swift-toml-edit native source-span API。
- x-chord-constraints は A方式(catalog + coverage test)で確定。真の単一 source 化(B方式)は不採用
  (ConfigWarning は補間メッセージで結合大・over-engineering)。必要なら将来再検討。

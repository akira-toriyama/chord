# config.toml オーサリング補助 (Taplo/schema) 強化

- Issue: Closes #138 (umbrella)。Sub: #144 A / #145 B / #146 C / #147 D / #148 E
- Status: in-progress (Phase A 実装中)
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

### Phase A (#144, low) — CI drift-guard (schema 形状不変) ← 実装中

- [ ] A1: `build.yml` に **emit-parity drift-guard**(`diff <(chord config --emit-schema) config.schema.json`、
      process-substitution で byte 一致維持。今 byte-identical 確認済)。
- [ ] A2: **ConfigWarning.Kind 3-place set-equality**(`scripts/check-warning-kind-sync.sh`、
      check-version-sync.sh 同型): Swift enum 23 == v3.json kind enum 23 == glossary §302。
      + `CaseIterable` round-trip 単体テスト(両方)。← #121 残 / 論点2 内包。
- [ ] A3: 共有 `.github` taplo.yml に **`taplo fmt --check`**(family-wide 採用)。要 family 一括 normalize。
      taplo pin 0.7.0 の flag 意味論確認 / 必要なら pin bump。

### Phase B (#145, low) — chord-local x-taplo editor-UX uplift (descriptor+emitter のみ)

- [ ] B1: `enumDocs` → `x-taplo.docs.enumValues`(action-mission-control/action-screenshot/repeat)。
- [ ] B2: `initKeys`(binding=[input,action-keys]、sequence=[prefix,timeout-ms])。※ `initKeys`(≠ initFields)。
- [ ] B3: markdownDescription は出さない。**array-example-as-string 欠陥修正**(SchemaEmit.swift:137)→
      高価値 example を `description` に畳む。
- [ ] B4: `x-chord-constraints` で ~11 個の runtime-only ルールを hover 可視化。**ConfigWarning と単一 source 共有**。
- [ ] B5: `config.schema.json` 再生成(A の drift-guard が機械強制)/ keySet 不変 / build+test green。

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

## 未達成・保留 (明示)

- Phase A〜E 実装はこれから(A 実装中)。各 phase の checkbox を該当 PR 内で更新。
- x-chord-constraints 単一 source 化の具体形は Phase B 着手時に確定(maintainer と確認)。

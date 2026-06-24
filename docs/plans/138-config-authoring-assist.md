# config.toml オーサリング補助 (Taplo/schema) 強化

- Issue: Closes #138 (umbrella)。Sub: #144 A / #145 B / #146 S1 / #147 S2 / #148 E
- Status: in-progress (A ✅ / B ✅ merged / 次=S1 sill 共有コア / E 残)
- Updated: 2026-06-24

## 🔖 次セッション着手ガイド (cold-start 用)

**着手対象: S1 (#146) — sill の decode-free 共有 schema コア。** 推奨は **設計先行**
(公開 API を1枚出す → maintainer 合意 → 実装。品質最優先・手戻り最小)。

S1 設計の出発点:
- **移設元 (chord)**: [Sources/ChordCore/ConfigSchema/SchemaDescriptor.swift](../../Sources/ChordCore/ConfigSchema/SchemaDescriptor.swift)(型)+
  [SchemaEmit.swift](../../Sources/ChordCore/ConfigSchema/SchemaEmit.swift)(lowering)。Phase B で
  `enumDocs`/`initKeys`/`xChordConstraints`/cross-field `ExclusionRule` 実装済 = **一般化の素材**。
- **移設先 (sill)**: `Sources/ConfigSchema/ConfigSchema.swift`(現状 `Spec<Root>` で decode+emit。
  arrayOfTables emit 対応だが **flat fields のみ・enumDocs/exclusions/nested/x-taplo 無し**)。
  → `Spec` とは別に **decode-free な新型群**(`SchemaField`/`ObjectShape`/`SchemaSection`/`ExclusionRule`)
  + lowering を追加。S3 で既存 `Spec.jsonSchema()` を新コア経由に。
- **設計要件**: descriptor はルールを純データ保持 = **emit + validate 両対応**(validator は S-validate)。
  chord(自前 descriptor)と sill `Spec`(flat decode)の両方が emit を共有。
- **S2 受け入れ条件**: chord 載せ替え後の `config.schema.json` が **byte-identical**
  (`ConfigSchemaDriftTests` + `ConfigSchemaShapeTests` + `ConfigConstraintCoverageTests` + `taplo lint` で担保)。

検証: `swift build` / `swift test`(Xcode でローカル可・386+ green)/ `npx --yes @taplo/cli@0.7.0 lint config.toml`。

**cross-repo 作業の鉄則 (本セッションの教訓 — 共有資産化で多発する)**:
- sibling repo は **fresh clone (SSH alias `ssh://github.com.akira-toriyama/akira-toriyama/<repo>.git`)** で作業。
  ローカル checkout は maintainer の未 push 作業で origin から乖離していることがある(wand で 42 file 乖離・config.toml だけのつもりが巻き込み)。
- **workflow ファイルの push は SSH 必須**(HTTPS token に `workflow` scope 無し → 拒否)。
- `gh pr merge --admin` は harness が**ブロック**(branch protection bypass)。`gh pr update-branch` → 通常 merge。
  perch は up-to-date 必須・squash merge。
- `rm` はシェル alias → `command rm`。taplo は未インストール → `npx --yes @taplo/cli@0.7.0`。
- **Project board #5**: PID `PVT_kwHOBYj5C84BZ-RS` / Status field `PVTSSF_lAHOBYj5C84BZ-RSzhU5HHw` /
  options: Done `98236657` · In Progress `47fc9ee4` · Ready `85c0755f` · Backlog `6a999963` · Icebox `a5a58e45` · Inbox `cc6b1dd6`。
- 投資調査の raw 出力は /tmp(ephemeral・消える)。要点は本 plan に集約済。再実行は workflow `chord-138-config-authoring-investigation`。

## ゴール

GUI なし family の中で chord の `config.toml` は最も複雑。**エディタ補助
(JSON Schema + Taplo) が事実上の UX** = config.toml は UI と言っても過言ではない。
徹底調査 → 設計確定 → **直列 PR(1 本ずつ merge)**で品質最優先に強化する。

**maintainer 方針 (2026-06-24)**: 他アプリも続く前提で **先行投資 OK**・
**sill / swift-toml-edit / 関連リポへの Push / PR / マージ OK**・破壊的変更 OK・
**全体の品質最優先(時間はかけてよい)**・進行を記録しながら進める。

## 北極星 (maintainer 認識合わせ 2026-06-24): 共有 schema エンジン (emit + validate)

**chord / facet / perch / wand / halo (+ glance) は「config.toml で設定 × swift app」**。
**facet / wand は大ボリュームで validation 必須の toml**。config.toml の authoring + validation を
family 共有資産にしたい。chord がその **pilot / 実 driver**。

- **1つの descriptor から3つを導出**(sill ConfigSchema「1 Spec で decode+emit」の1段拡張):
  - **editor schema emit** → taplo(補完 + 構造 + cross-field を live squiggle)
  - **runtime validate** → `config --validate` 相当(同じルールを load 時に enforce)
  - **decode**(各自)
  → 同一 descriptor が editor と runtime を駆動し「editor は緑なのに load で落ちる」ギャップを構造的に縮める。
- **二層 validation はどのアプリも同じ**: 構造 + cross-field(型/enum/range/required/anyOf/oneOf/
  forbids/dependency)= **共有**、意味(参照解決/派生キー一意性)= **各アプリ bespoke**。
- **decode は共有しない**: chord の命令的 DSL(array-of-tables 展開/alias/keySet 検証)は sill の
  flat-decode に乗らない。共有するのは **descriptor 語彙 + emit + generic validate**。
- 当初 C(typed examples + markdownDescription)は B の発見で**廃止**: markdownDescription は taplo で
  死に(family に消費者ゼロ)、examples は hover 非表示。真の lever は `x-taplo.docs.enumValues`。
- **役割**: chord = emit 側の driver / descriptor 提供者(runtime 検証は既に bespoke parser が enforce 済)。
  facet/wand = **共有 validator の主受益者**(大 toml・cross-field runtime 検証が薄い)。
- アーキ **Path Y**: sill に decode-free な共有コア新設(chord B の型/emitter を一般化移設)。
  descriptor は **emit + validate 両対応**(ルールを純データで保持)で設計、実装は **emit 先行**。

## 徹底調査の結論 (workflow `chord-138-config-authoring-investigation`, 13 agents, 2026-06-24)

- INPUT config schema は `Sources/ChordCore/ConfigSchema/` の **データのみ descriptor** `ChordConfigSchema`
  が単一 SoT。`config --emit-schema` (SchemaEmit) と parser の unknown-key check (StructuralCheck) の
  **両方**を駆動 → drift しない。emit 先は `config.schema.json`(`#:schema` 紐付け済)。**OUTPUT wire
  schema (`chord.bindings.v3.json`) とは別物 — 本件は INPUT 側のみ、wire 契約に触れない**。
- `markdownDescription` は **taplo で死に**(taplo は `description` を Markdown 描画)。真の lever は
  `x-taplo.docs.enumValues` / `initKeys` / examples を description に畳む。
- sill `ConfigSchema` (316行): `Spec<Root>` で decode + emit を兼ねる。arrayOfTables も emit 対応だが
  **flat fields のみ・enumDocs/exclusions/nested/x-taplo 無し**。facet は採用済(45 description fields)。

## 直列 PR 計画 (risk-monotonic・各 phase 独立 shippable・1 PR ずつ merge)

### Phase A (#144, low) — CI drift-guard (schema 形状不変) ✅ DONE (chord#149 / perch#136 / wand#165 / .github#7)

- [x] A1: emit-parity drift-guard → 既存 `ConfigSchemaDriftTests` で担保済と判明。冗長な build.yml step は不採用。
- [x] A2: `scripts/check-warning-kind-sync.sh`(pre-build fast fail)+ `ConfigWarningKindSyncTests`(compiled-enum 権威)。Swift 23 == v3.json 23 == glossary §302。chord#149。
- [x] A3: 共有 `.github` taplo.yml に `taplo fmt --check`(family-wide)。caller=chord/facet/perch/wand/sill のみと実測。perch#136 / wand#165 正規化 → .github#7 flip → 5 caller workflow_dispatch 全 green。pin 0.7.0 OK。

### Phase B (#145, low) — chord-local x-taplo editor-UX uplift ✅ DONE (chord#150)

- [x] B1 enumDocs→x-taplo.docs.enumValues / B2 initKeys / B3 examples 全廃→description 畳み / B4 x-chord-constraints(catalog + ConfigConstraintCoverageTests) / B5 config.schema.json 再生成(1323行)・393 green。
- 付随: deflake `showWithoutFile`(chord#151、固定 tmp パス並列分離)。

### 共有 schema エンジン program (本命) — S1〜S5 + S-validate

> 当初 Phase C/D を「共有 schema エンジン(emit + validate)」に統合。実装は **emit 先行**。

- [ ] **S1 (sill, #146)**: decode-free 共有コアを sill `ConfigSchema` に新設 —
      `SchemaField`/`ObjectShape`/`SchemaSection`/`ExclusionRule`(enumDocs/initKeys/xChordConstraints/
      rejected/nested 付)+ Draft-07 & x-taplo & cross-field lowering(= chord B の型/emitter を一般化移設)。
      **descriptor はルールを純データで保持 = emit と validate の両対応**(validator は S-validate)。
      sill minor bump。sill tests(chord の shape/emit テスト移植)。
- [ ] **S2 (chord, #147)**: `ChordConfigSchema` を sill 共有型に載せ替え(自前 SchemaEmit 削除・descriptor
      データと StructuralCheck/keySet は local 維持)。sill dep bump。**byte-identical** config.schema.json。
- [ ] **S3 (sill)**: 既存 `Spec<Root>.jsonSchema()` を共有コア経由に + `Spec.Field` に enumDocs(S1 内包可)。
- [ ] **S4 (facet)**: sill bump + enum フィールドに enumDocs → facet エディタ UX。
- [ ] **S-validate (sill)**: 共有 generic runtime validator(descriptor のルールを decode 後の値に実行 → `[error]`)。
      **facet/wand の大 toml 検証が主目的**。editor schema と同じルールを load 時にも enforce。facet/wand 採用時。
- [ ] **S5 (perch/wand/halo)**: sill ConfigSchema + schema emission + validator 採用。各 app の別 issue・将来。

### Phase E (#148, med) — swift-toml-edit native source-span API

- [ ] E: swift-toml-edit に source-span/location API → chord の `__line__` plumbing 撤去 →
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
- 2026-06-24: investigation workflow 完了 (13 agents)。markdownDescription が taplo で死にと判明。
- 2026-06-24: **Phase A 完了** — chord#149。A3 family-wide: perch#136 / wand#165 → .github#7 flip → 5 caller 全 green。#144 close。
  ※ wand ローカル checkout が origin 乖離 → fresh clone(SSH)で作業(教訓: sibling 直 push 注意)。
- 2026-06-24: **Phase B 完了** — chord#150 + chord#151(deflake)。393 green。
- 2026-06-24: **認識合わせ(maintainer)** — 北極星を「共有 schema エンジン(emit + validate)」に確定。
  ① authoring+validation を family(chord/facet/perch/wand/halo)共有資産に、chord が pilot。
  ② decode は各自・descriptor 語彙/emit/generic-validate を共有(Path Y: sill decode-free コア)。
  ③ markdownDescription 廃止。④ facet/wand(大 toml)が validator 主受益者。実装は emit 先行。

## 未達成・保留 (明示)

- **S1 (#146)**: sill 共有 emit コア。次に着手。
- **S2 (#147)**: chord を共有コアに載せ替え(byte-identical)。
- **S3/S4/S-validate/S5**: sill Spec 統合 / facet 採用 / 共有 validator / perch/wand/halo 採用。
- **Phase E (#148)**: swift-toml-edit span API。
- x-chord-constraints は A方式で確定(真の単一 source 化は不採用・over-engineering)。

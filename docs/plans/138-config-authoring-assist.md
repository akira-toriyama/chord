# config.toml オーサリング補助 (Taplo/schema) 強化

- Issue: Closes #138 (umbrella)。Sub: #144 A / #145 B / #146 S1 / #147 S2 / #148 E
- Status: in-progress (A ✅ / B ✅ / S1 ✅ / S2 ✅ / S3 ✅ (sill v1.26.0) / **S4 ✅ merged (facet #338+#339)** — emit+authoring 半分 完了 / 残=S-validate・S5・E は **consumer-gated**)
- Updated: 2026-06-25

## 🔖 次セッション着手ガイド (cold-start 用)

**着手対象: S4b (facet) — enum フィールドに `enumDocs` を付与 (taplo per-value hover)。**
S3 merged (sill v1.26.0)・S4a merged 待ち。`Spec.Field.enumDocs` は v1.26.0 に在る。

**S4b の足場 (S4a で facet は sill 1.26.0 に乗った)**:
- facet の `FacetConfig+Spec.swift` の `.str(... enum: ...)` フィールド (theme.name / window.raise-on-open /
  grid.label-position / animation.curve / rail.edge / tree.preview-mode / border.effect / exclude.action 等) に
  `enumDocs:` を足す。`ConfigSchema.Field.init` は既に `enumDocs:` 引数を持つ (S3)。facet の builder
  (`str`/`descOnly`) に `enumDocs` パススルーを足すのが実装の中心。
- **hover 文言は内容オーサリング** → ドラフトを作って maintainer レビュー (theme 名は大量・全部に文言は不要、
  代表的な enum=curve/edge/preview-mode/action 等に絞るのが現実的)。
- 完了後 `facet --emit-schema > config.schema.json` 再生成 + drift test green を確認して PR。

**S4 スコープ実態 (調査済 2026-06-25・当初の「大移行」懸念は否定された)**:
- facet @ origin/main は sill 1.26.0 + swift-toml-edit で **ソース改変ゼロ・クリーンビルド・932 test green**。
  必要変更は Package.swift の依存張り替えのみ (sill 0.9→1.26 + 撤去された `Toml` を swift-toml-edit へ)。
- schema 差分は **純 additive** (theme/effect の enum 値が増えただけ・構造変更ゼロ)。→ S4a として分離・実施済。
- facet のアクティブ作業は branch `feat/section-focus-cli` (clean・未 push 1 commit) に隔離・main 乖離なし。
  S4a は origin/main から独自 branch。衝突面は Package.resolved/config.schema.json のみ (小)。

S1/S2 で確立した事実(再利用の足場):
- **共有コア (sill 1.25.0)**: `Sources/ConfigSchema/SchemaDescriptor.swift`(型)+
  `SchemaDescriptorEmit.swift`(Draft-07 lowering + `EmitOptions`)。型は `SchemaField`/
  `ObjectShape`/`SchemaSection`(nested `Kind`)/`ExclusionRule`/`NestedTable`/root `SchemaDescriptor`。
  app 固有 spelling(`constraintsKey`/`escapeSlashes`/`trailingNewline`)は `EmitOptions` knob。
  `x-taplo` は固定。データは **let**(不変)・`EmitOptions` は **var**。
- **chord 載せ替え済 (S2)**: [SchemaDescriptor.swift](../../Sources/ChordCore/ConfigSchema/SchemaDescriptor.swift)
  は ChordConfigSchema の **データ + RuntimeConstraint catalog** のみ(型/emit は sill)。
  `ChordConfigSchema.jsonSchema` は `descriptor.jsonSchema(options: .init(constraintsKey: "x-chord-constraints"))`。
  SchemaEmit.swift は **削除**。StructuralCheck.swift は `import ConfigSchema` 追加。

S3 の出発点:
- **移設先 (sill)**: `Sources/ConfigSchema/ConfigSchema.swift` の `Spec<Root>.jsonSchema()` は
  まだ独自 lowering(SchemaNode tree・flat fields のみ・`.withoutEscapingSlashes`＋末尾改行)。
  → S1 コア経由に統合。注意: `Spec` は **dotted header の nested tree 畳み込み**・dynamicTable
  permissive を持つので、S1 `SchemaSection` 語彙に **header 分割 + permissive object** の表現を足すか、
  `Spec` 側で descriptor へ変換する adapter を書く。facet が `Spec` を採用済(45 desc fields)なので
  byte-identical を `ConfigSchemaTests.testJSONSchemaIsValidAndStable` 等で担保。
- S4(facet enumDocs)/ S-validate(共有 generic validator)/ S5(perch/wand/halo)/ E は後続。

検証: `swift build`(local gate)/ `swift test`(Xcode でローカル可・chord 393 / sill 683 green)/
`npx --yes @taplo/cli@0.7.0 lint config.toml`。

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

- [x] **S1 (sill, #146)**: decode-free 共有コアを sill `ConfigSchema` に新設 —
      `SchemaField`/`ObjectShape`/`SchemaSection`/`ExclusionRule`/`NestedTable`/`SchemaDescriptor`
      (enumDocs/initKeys/constraints/rejected/nested 付)+ Draft-07 & x-taplo & cross-field lowering。
      app 固有 spelling は `EmitOptions`(constraintsKey/escapeSlashes/trailingNewline)。sill PR #76 →
      **v1.25.0** tag。35 ConfigSchema tests(31 new)/ 683 green。28-agent adversarial review 適用済。
- [x] **S2 (chord, #147)**: `ChordConfigSchema` を sill 共有型に載せ替え(自前 SchemaEmit.swift 削除・
      descriptor データと RuntimeConstraint/StructuralCheck/keySet は local 維持)。sill pin 1.25.0。
      **config.schema.json byte-identical**(`chord config --emit-schema` == committed・diff 0)。393 green。
- [x] **S3 (sill)**: `Spec<Root>.jsonSchema()` を共有 `SchemaEmit`(emitSection/emitObject/emitField/serialize の
      internal 名前空間)経由に統合。`Spec` は dotted-header 畳み込みを保持しつつ各 node を `ObjectShape` に変換
      → 共有 emitter で lower。descriptor 語彙を additive 拡張(`.number`/`arrayItemEnum`/inclusive min・max/
      typed defaults・`ObjectShape.permissive`+`objects:[NestedObject]`)・`Spec.Field.enumDocs` 追加。
      **byte-identical 検証**: Spec golden diff 0 / chord `--emit-schema` 1323行 diff 0 / sill 707 + chord 393 green。
      28→**adversarial review (24 agents)** で latent byte-divergence 2件修正(documented root doc 欠落・
      stringArray への scalar-only metadata 漏れ)。branch `138-s3-spec-shared-lowering`(未 push)。
- [x] **S4a (facet)**: sill 0.9.0 → 1.26.0 bump + `Toml` を swift-toml-edit へ張り替え + config.schema.json 再生成。
      ソース改変ゼロ・932 test green・schema 差分は純 additive (theme/effect enum 値)。facet PR #338(green・merge 待ち)。
- [x] **S4b (facet)**: enum フィールドに `enumDocs` → taplo per-value hover。`str`/`descOnly` builder に `enumDocs` パススルー +
      4 enum (window.raise-on-open / rail.edge / tree.preview-mode / exclude.action) に index-aligned hover。文言は各 enum の
      code doc から逐語。catalog enum (theme/effect) と主観的な animation.curve は意図的に除外 (maintainer 判断)。facet PR #339(green・wording レビュー待ち)。
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

- 2026-06-25: **S4b merged (facet #339)** — wording 承認 → update-branch → squash merge。**S3+S4 で #138 の emit+authoring 半分が完了**。
  残り (S-validate/S5/E) は consumer-gated と整理(下記「次の判断」)。
- 2026-06-25: **S4b 完了 (facet PR #339・green・wording レビュー待ち)** — 4 enum に `enumDocs` per-value hover。
  `str`/`descOnly` builder に `enumDocs` パススルー。文言は code doc 逐語。catalog (theme/effect) と主観的 curve は除外。
  schema 差分は x-taplo 4 ブロックのみ・560 test green。S4b の hover 文言は「レビュー前提のドラフト」と PR 明記。
- 2026-06-25: **S4a merged (facet #338)** — update-branch → squash merge (`ec52bfd`)。facet が sill 1.26.0 に乗った。
- 2026-06-25: **S4a 完了 (facet PR #338・green・merge 承認待ち)** — facet を sill 0.9.0 → 1.26.0 bump +
  `Toml` を swift-toml-edit へ張り替え + config.schema.json 再生成。**調査で当初の「大移行」懸念は否定**:
  facet @ origin/main は新 sill で **ソース改変ゼロ・クリーンビルド・932 test green**、schema 差分は純 additive
  (theme/effect enum 値が増えただけ・構造変更ゼロ)。PR は main から 1 docs commit BEHIND (overlap なし→update-branch クリーン)。
  次=S4b(enumDocs)。
- 2026-06-25: **S3 merged + released** — sill PR #77 merged → main `0a99a8c` → **v1.26.0 tag (push 済)**。
- 2026-06-25: **S3 完了 (commit 済)** — sill branch `138-s3-spec-shared-lowering` @ `/tmp/sill-s3`。
  `Spec.jsonSchema()` を共有 `SchemaEmit` 経由に統合(自前 fieldSchema/objectSchema/serialize 廃止)。
  descriptor 語彙を additive 拡張(下記設計どおり)・`Spec.Field.enumDocs` 追加。**全 byte-identical 検証 pass**
  (Spec golden facetlike diff 0・chord 1323行 diff 0・sill 707 green・chord 393 green)。**24-agent adversarial
  review** 適用 → confirmed 9件中: ① documented root `Section("")` の description 欠落(`sectionDoc:""` hardcode
  バグ)を `rootShape.doc` 渡しで修正、② `.stringArray` field の stray `domain`/`min`/`max` が array node に漏れる
  のを `.scalar` gate で修正、③ `doc:""` の description 省略は **意図的正規化**として comment+test で固定
  (historic は `"description":""` を emit・実 spec は `doc:""` を渡さない・shared `doc:String` を Optional 化しない)。
  follow-up: SchemaField の 5 typed default を単一 `DefaultValue?` enum に統合(breaking・chord descriptor 同時移行要 → 別 PR)。
  **教訓: review workflow の agent は default で write 権限を持ち、probe で `git clean`/`stash` を打って untracked
  test file を消した**。今後 review は read-only(Explore 型)か repo copy 上で。本件は untracked 1 ファイル消失のみ・復元済。
- 2026-06-25: **S3 着手** — sill fresh clone `/tmp/sill-s3`(origin/main = S1 merge b4846a3 / v1.25.0)。
  `Spec<Root>.jsonSchema()`(独自 SchemaNode lowering)→ S1 共有 emitter 経由に統合する設計確定:
  - **ONE lowering = `emitField`/`emitObject`/`serialize` を共有**(internal `SchemaEmit` 名前空間に集約)。
    `Spec` は SchemaNode 畳み込み(dotted header→nested tree)を保持しつつ、各 node を `ObjectShape` に変換し
    `emitObject` で lower。root も ObjectShape 1 枚 + `$schema`/`title`。
  - **descriptor 語彙の追加**(全て additive・default が現状維持 → chord byte-identical):
    `SchemaField`: `.number` shape / `arrayItemEnum` / inclusive `minimum`+`maximum`(Double) /
    `defaultString`+`defaultNumber`+`defaultStringArray`。`ObjectShape`: `permissive`(→additionalProperties)+
    `objects:[NestedObject]`(nested 単一 object・dotted 畳み込み用)。`Spec.Field`: `enumDocs`(S4 facet 用)。
  - **byte-shape 要注意点**(golden 実測): min/max は **Double** で emit(JSONSerialization が 30.0→`30`・
    0.1→`0.10000000000000001`)。Spec の arrayOfTables doc は **items 側**(array node は bare)=
    descriptor の `NestedTable` 規約と一致(section-level `.arrayOfTables` の array-doc 規約とは別=chord 用に温存)。
    permissive empty table は `properties` 省略 → emitObject に `if !props.isEmpty` guard 追加(chord は props 常に非空 → 無影響)。
  - **検証ハーネス**: golden capture 済 `/tmp/golden/PRISTINE-{facetlike,nested}.json`(current-main Spec 出力・
    facet 全 shape 忠実転写 + dotted/quoted/top-level)。S3 後に byte diff 0 を要求。+ chord `--emit-schema` diff 0 + sill 全 test green。
- 2026-06-24: **S1 完了** — sill PR #76 merged → **v1.25.0** tag。decode-free 共有コア
  (`SchemaDescriptor` 型群 + `SchemaDescriptorEmit` lowering + `EmitOptions`)を `ConfigSchema`
  モジュール top-level に追加(既存 `Spec<Root>` は無改変・S3 で統合)。emit は chord の SchemaEmit を
  逐語移植し **app 非依存に一般化**(`x-chord-constraints`/slash-escape/末尾改行 → `EmitOptions`、
  `x-taplo` は固定)。データは `let`・review 指摘で immutable 化。テストは sill 慣習の **XCTest**
  (synthetic fixture 全網羅 + 否定パス)。**28-agent adversarial review** を適用(immutability /
  doc 明確化 / negative-path test)。sill 非 issue-tracker → PR は chord#146/#138 を本文リンク。
- 2026-06-24: **S2 完了** — 本 PR。chord pin → sill 1.25.0、ChordConfigSchema を sill 型に載せ替え、
  SchemaEmit.swift 削除、StructuralCheck に `import ConfigSchema`。`xChordConstraints:`→`constraints:`。
  **`chord config --emit-schema` が committed config.schema.json と byte-identical**(diff 0・
  git status でも未変更)。393 green。S1 で chord descriptor を sill 型で再構成し byte-parity を
  事前検証済(throwaway・未 commit)だったため手戻りゼロ。
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

- **S3 follow-up (sill, 別 PR)**: `SchemaField` の 5 typed default Optional(defaultBool/Int/String/Number/StringArray)を
  単一 `DefaultValue?` enum に統合(「default は高々1個」を型で表現・hand-written descriptor の silent last-wins 防止)。
  **breaking**(chord descriptor の `defaultInt:`→`default:.int()` 同時移行要)ゆえ S3 本体から分離。優先度: 中。
- **S-validate / S5 は consumer-gated (要 maintainer 判断)**: #138 の emit+authoring 半分 (S3+S4) は完了。残りは:
  - **S-validate (sill)**: 共有 generic runtime validator。だが chord は runtime 検証を bespoke parser で enforce 済 →
    **主受益者は facet/wand の大 toml だが両者とも今 config 検証を作っていない** (facet は別 feature 開発中・wand dormant)。
    → driving consumer 無しで作ると **speculative API 設計** になり手戻りリスク。plan 北極星も「facet/wand 採用時」。
    実 consumer が検証ペインを持った時に着手するのが筋。
  - **S5 (perch/wand/halo)**: 各 app dormant → activate 時。
  - **Phase E (swift-toml-edit span API)**: 最低優先・E。
  → #138 umbrella を「emit 半分 done」で一旦締め、consumer-gated 分を別 issue に切り出して close する手もある (maintainer 判断)。
- 追加候補(任意・S4 系): theme/effect catalog や animation.curve に hover を足すか(現状は意図的除外)。
- **S-validate (sill)**: 共有 generic runtime validator(descriptor のルールを decode 後の値に実行)。
  facet/wand の大 toml が主受益者。
- **S5 (perch/wand/halo)**: sill ConfigSchema + emission + validator 採用。各 app の別 issue。
- **Phase E (#148)**: swift-toml-edit span API。
- x-chord-constraints は A方式で確定(真の単一 source 化は不採用・over-engineering)。

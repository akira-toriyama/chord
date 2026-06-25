# #148 (#138-E): swift-toml-edit native source-span API → remove chord `__line__` plumbing

- Issue: Closes #148 (Refs #138)
- Status: in-progress
- Updated: 2026-06-25

## ゴール

swift-toml-edit に **native な source-span API** を足し、chord の
`__line__` synthetic-key plumbing (leaky abstraction: Config 層の
skip-guard + desugaring re-thread) を**完全撤去**する。`config --validate`
の error 位置情報を行 (将来は列) 単位で持てる土台にする。完了条件:

- swift-toml-edit 2.0.0: `Toml.parse` の出力から `__line__` が消え、
  `parseSpanned` が clean tree + `SpanIndex`(構造パス keyed・line + 任意 column)
  を返す。既存の round-trip / toml-test conformance / `parseFlat` は不変。
- chord: `TOML.lineKey` / `__line__` 文字列が ChordCore から消滅。
  skip-guard 6 箇所・re-thread 5 箇所を撤去。warning の行帰属は従来どおり
  (`(config.toml:N)`)・wire (`source_line: Int?`) 不変 = chord.bindings.v3 据え置き。
- 386 tests green (ローカル `swift test` / Xcode 26.5)。
- 家族の other STE consumer (facet/wand/perch) が壊れないことを確認。

## 設計決定 (調査+設計 workflow wf_bc369240-0d7, 2026-06-25)

**統合案 = clean な public 契約(Design 2)+ 低リスク実装(Design 3)**。
maintainer 指針「破壊的OK / 高品質 / 時間OK / ただし過剰回避」を反映。

- chord は **lossy `Toml.parse` のみ**使用 (Config.swift:57)。Annotated DOM
  非使用。行番号は AoT row に inject された `__line__`(`.int`)を
  `row.sourceLine`(TOML.swift:38)で読むだけ。
- swift-toml-edit に **native span 不在**(lossless DOM は `raw` 文字列のみ・
  line/col 構造化せず / strict decode は `line:0` 固定)。→ #148 は「露出」では
  なく「**新規追加**」。
- **採用**: lossy parse path に clean な span sidecar を載せ、`__line__` を
  parse 出力から**本当に撤去**(高品質)。ただし実装は**既存の実証済み line
  parser を拡張**して span を記録(lib が意図的に gate している Annotated-DOM
  再導出 = post-M2 unification は前倒ししない → strict-tree 乖離リスク回避 =
  過剰回避)。等価性テストで gate。
- **却下**: Design 1 (`Toml.Value` に `.span` case 追加 → alias loop /
  StructuralCheck `default:` で誤 warning の runtime foot-gun)。
- **非前倒し**: Design 2 の Annotated-DOM 再導出 + per-field warning column 化
  (lib gating 前倒し・makeBinding 大改修・chord 過剰)。column は SourceSpan の
  optional field として出すが chord 側 wire は line のみ(per-field 化は別 issue)。

**cross-repo の真実 (origin 確認済み・stale local ではない)**:
- `Toml.parse`(nested)+ `lineKey` を読むのは **chord だけ**。
- wand (Config.swift:114,126) / perch (Config.swift:566) / facet は全部
  `Toml.parseFlat`(`__line__` を inject しない)→ `__line__` 撤去は**無傷**。
- 4 repo とも STE `1.0.0` を `.upToNextMinor(from: "1.0.0")` で pin →
  2.0.0 は自動で拾われない(controlled)。chord のみ pin bump 必須。

## API 設計 (swift-toml-edit 2.0.0) — Option R: span を `Row` に持たせる

workflow の 3 案(`.span` enum case / Annotated 再導出 / 既存 key を wrap)より
chord の value-copy desugaring に合致する **第4の統合案** を採用:

新ファイル `Sources/Toml/Span.swift`(`Annotated.swift`/`TypedValue.swift`/
`Serialize.swift`/`TaggedJSON.swift` は **触らない** = render / toml-test 不変):

```swift
public extension Toml {
  /// 1-based source location. `column` = 行頭 (leading ws 後) の 1-based 桁。
  struct SourceSpan: Sendable, Equatable, Hashable, Codable {
    public var line: Int
    public var column: Int?
    public init(line: Int, column: Int? = nil)
  }
  /// `[[array-of-tables]]` の 1 行 = key/value の dict + その `[[header]]` の span。
  /// `parse`(nested strict)だけが構築。`parseFlat` は従来どおり `[[String:Value]]`。
  struct Row: Sendable, Equatable {
    public var fields: [String: Value]
    public var span: SourceSpan?
    public init(fields: [String: Value] = [:], span: SourceSpan? = nil)
    public subscript(_ key: String) -> Value? { get set }      // row["input"] 互換
  }
}
```

`Toml.swift` の変更(**ここだけが破壊的**・chord 専用 surface):
- `Value.arrayOfTables([[String: Value]])` → **`.arrayOfTables([Row])`**。
- `asArrayOfTables` → `[Toml.Row]`。
- `appendArrayOfTablesRow` は `Row(fields: [:], span: SourceSpan(line: lineNo,
  column: leadingWS+1))` を append(旧 `[lineKey: .int(...)]` seed を置換)。
  `writeIntoArrayOfTablesRow` は `row.fields` に書く。nested AoT も各 Row が
  自分の span を持つ。
- `Toml.lineKey` / `__line__` injection は **削除**。
- `parse(_:) throws -> [String: Value]` の **signature は不変**(中の
  `.arrayOfTables` 要素型だけが変わる)。`parseFlat` / `Document` は完全不変
  (flat consumer = wand/perch/facet は無傷)。**SpanIndex も parseSpanned も不要**。

lib test churn: `LossyProjectionTests`(`row[lineKey]?.asInt` → `row.span?.line`・
`.arrayOfTables([[...]])` リテラル → `[Row(...)]`)+ `ReviewFixesTests` の
`asArrayOfTables` 読み。round-trip / toml-test / Edit は不変。

## 直列 PR (risk-monotonic / 各 repo は最新化してから着手)

| PR | repo | 内容 | risk |
|---|---|---|---|
| **PR-1** | swift-toml-edit (2.0.0) | `Span.swift`(`SourceSpan`+`Row`)追加・`Value.arrayOfTables` を `[Row]` 化・`__line__`/`lineKey` 撤去・span tests。round-trip / toml-test / parseFlat 不変。tag v2.0.0 | low-med |
| **PR-2** | chord | pin → `.upToNextMajor(from: "2.0.0")`・local `sourceLine` accessor 削除(同 commit)・`parseSpanned` 採用・SpanIndex を構造パスで thread・skip-guard 6 + re-thread 5 撤去・docs/glossary 同期。wire/schema 不変 | med |
| **PR-3** | wand / perch | pin → 2.0.0 + `swift build` 検証(parseFlat consumer なので clean)。family を 1 version に揃える | low |

facet: **今日 active**(maintainer 開発予定あり)→ 触らない。parseFlat consumer
で STE major に無影響なので 1.0.0 据え置きで問題なし。quiet になった時/別途 bump。

### chord 側 desugaring 写像 (PR-2 の肝)

`.asArrayOfTables` が `[Toml.Row]` を返すので、行は **`row.span?.line`** で読む。
`makeBinding` / desugar 関数は `[String:Value]` ではなく `Toml.Row` を受け渡し
(深い field parser = parseAction/parseCondition 等は `row.fields` を渡して
`[String:Value]` のまま据え置き → churn を desugar 層に限定)。span は `var synth
= row` の value-copy で自然に同行する(re-thread コード不要)。per-site:
- `makeBinding(from: Row, ...)`: `let line = row.span?.line`(旧 `row.sourceLine`)。
- Config+Remap.swift:120 (re-thread) → **削除**。synth = `Row(fields:[…], span: row.span)`。
- Config+Expansion.swift:126 (per-app・**entry-line wins**) → **削除**。`var synth = row`
  が base span を継ぐ → entry がある時だけ `synth.span = entry.span`(`entry.span ?? row.span`)。
- Config+Sequence.swift:156 (prefix) → **削除**。`Row(fields:[…], span: row.span)`。
- Config+Sequence.swift:223-225 (child・child-line wins) → **削除**。`var childRow = child`
  が child 自身の span を継ぐ(nested AoT row なので parser が付与)→ 親 fallback は防御的に保持。
- Config+Expansion.swift:195-202 (fallback inputs[]) → `var synth = row` が span を継ぐ(変更不要)。
- skip-guard: Config.swift:90,105,136,197(`[options]`/alias `[table]` = そもそも
  `__line__` 非注入の dead guard)+ StructuralCheck.swift:41,83(AoT row from `Row.fields`
  に magic key 無し)→ すべて **削除**。StructuralCheck の `switch value` `default:` は
  新 Value case を足さない(`.arrayOfTables` の要素型変更のみ)ので安全。

## 進行ログ (execute)

- 2026-06-25: 調査+設計 workflow (understand×3 / design×3 / critique) 完了。
  swift-toml-edit に native span 不在を確認。chord が唯一の `parse`+`lineKey`
  consumer、wand/perch/facet は parseFlat で無傷と origin 確認。設計を統合案に確定
  (maintainer: 破壊的OK/高品質/過剰回避)。plan file 作成。
- 2026-06-25: **PR-1 実装完了**(swift-toml-edit `feat/source-span-row`・local commit
  `e45de34`)。`Span.swift`(`SourceSpan`+`Row`+subscript)新設・`Value.arrayOfTables`
  を `[Row]` 化・`appendArrayOfTablesRow` が span 付き `Row` を seed・`lineKey`/`__line__`
  撤去・`asArrayOfTables -> [Row]`。`LossyProjectionTests` 修正 + span tests 2 本追加。
  **118 tests green**(round-trip / toml-test / Edit / parseFlat 不変)。CLAUDE.md 更新。
- 2026-06-25: **PR-2 実装完了**(chord `feat/148-toml-source-span`・**未 commit**:
  release 時に lib tag→pin bump→単一 buildable commit が正しい lockstep)。makeBinding に
  `sourceLine: Int?` param 追加・desugar は `Row` 受け→`row.span?.line` 解決・synth は
  pure dict + 明示 line・re-thread 5 + skip-guard 6 撤去・StructuralCheck/ConfigWarning/
  CLAUDE.md 更新。検証用 local path-dep でビルド。**393 tests green**。実バイナリ smoke:
  `(config.toml:6): missing 'input'` で行帰属 OK・`--show --json` の `source_line` 不変。
- 2026-06-25: **PR-3 検証完了**(wand/perch を fresh clone→local lib path-dep→`swift build`)。
  **両者ゼロコード変更でビルド成功** = parseFlat consumer は additive-safe を実証。検証 clone は撤去。
  次の一手 = **レビュー → OK 後に push/tag/merge 連携**(下記)。

## release 連携手順 (OK 後)

1. swift-toml-edit: `feat/source-span-row` を push → PR → merge → **tag `v2.0.0`** push。
2. chord: Package.swift を `.package(path:...)`(TEMP)→ `.upToNextMajor(from: "2.0.0")` に戻す・
   `swift package update swift-toml-edit`・build+test 再確認 → **単一 commit**(sources +
   Package.swift + Package.resolved + docs)→ push → PR(`Closes #148`)。
3. wand / perch: fresh clone → pin を `.upToNextMajor(from: "2.0.0")` に bump →
   `swift package update` → build 確認 → push → PR(family を 1 version に揃える)。

## 未達成・保留

- [x] PR-1: swift-toml-edit 2.0.0 (`SourceSpan`+`Row` + `__line__` 撤去 + tests) — local commit 済、push/tag 未
- [x] PR-2: chord 移行 (de-magic + docs) — 実装+検証済、pin bump+commit は release 時
- [x] PR-3: wand / perch ビルド検証 — ゼロ変更で green、pin bump+commit は release 時
- [ ] **push/tag/merge 連携**(上記手順・maintainer OK 待ち)
- [ ] facet: STE 2.0.0 への pin bump(無影響だが family を 1 version に。**今日 active なので未着手** → quiet 時 or 別途 issue)
- [ ] **別 issue 化(過剰回避で #148 から切り出し)**: column の per-field warning 化
      + lossy parse の Annotated-DOM 再導出 (post-M2 unification)。SourceSpan は column
      を既に持つ(row header 位置)が、chord warning を per-field 化して `(config.toml:N:C)`
      を出すのは別スコープ。
- [ ] 別 issue (既知・S3 follow-up): SchemaField の 5 typed default → 単一 `DefaultValue?` enum
- [ ] facet: STE 2.0.0 への bump(無影響だが family を 1 version に揃えるため。
      **今日は active なので触らない** → quiet 時 or 別途。issue 化 or この行で追跡)
- [ ] **別 issue 化(過剰回避で #148 から切り出し)**: column の per-field warning
      化 + lossy parse の Annotated-DOM 再導出 (post-M2 unification)。SourceSpan に
      column を載せる土台は #148 で入るが、chord の warning を per-field 化して
      `(config.toml:N:C)` を出すのは別スコープ。
- [ ] 別 issue (既知・S3 follow-up): SchemaField の 5 typed default → 単一
      `DefaultValue?` enum(#138 memo 参照・#148 とは独立)

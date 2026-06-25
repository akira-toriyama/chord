# #130 — output macro timing (inter-key delay 半分)

Part of #130. ZMK `&macro` 由来。#130 は2点 (inter-key delay / cross-key
modifier-hold) を含むが、issue 自身が「分割が無難」と判断。**この PR は
delay 半分のみ**実装し、cross-key modifier-hold は follow-up issue に切り出す。
branch: `feat/130-action-keys-delay`.

## ゴール

`action-keys` 配列（primary + extraDownActions）のキー間に
`action-keys-delay-ms = N` でディレイを挟む。高速アプリ
(terminal/editor/game) のゼロ間隔取りこぼし対策。

**設計の肝**: pacing は tap thread を block してはならない。consume 判定は
即同期 return したまま、paced 出力は専用 serial queue
(`chord.dispatch.macro`) にオフロード（既存 `chord.state.timer` /
`chord.query` と同型）。

## 計画チェックリスト

- [x] **Model**: `Binding.actionKeysDelayMs: Int?` (init param 既定 nil)。
- [x] **Warning kind**: `ConfigWarning.Kind.actionKeysDelayParseError = "action-keys-delay-parse-error"`
  (granular-kind 規約に合わせ専用 kind。`holdWhileParseError` と同型)。
- [x] **Parse**: `parseActionKeysDelay(row:…) -> OptionalParse<Int>?` を
  `parseHoldWhileTimeout` と同型で新設。非 int / ≤0 は binding drop + warning。
  makeBinding で thread。
- [x] **per-app 継承**: per-app override が base の delay を継ぐか確認
  (expandBindingPerApp の field merge を見て決定)。
- [x] **Descriptor**: `SchemaField("action-keys-delay-ms", .integer, exclusiveMinimum: 0)`
  を `scopeFields()` に追加 (bindings/per-app/fallback/sequence-children に展開・
  remap は single-key なので対象外で正しい)。
- [x] **config.schema.json** 再生成 (`chord config --emit-schema > config.schema.json`)。
- [x] **wire schema** `docs/schema/chord.bindings.v3.json` の `dropped[].kind` enum に
  新 kind を additive 追加 (forward-compatible・major bump 不要)。
- [x] **Dispatch**: `ActionDispatcher.postKeysSequence(_ keys:[(Modifiers,UInt16)], delayMs:, name:)`
  — `chord.dispatch.macro` serial queue に async、キー間 `Thread.sleep`、各キーは既存
  `postKeys` 経由 (sentinel + flags 再利用)。
- [x] **Controller**: handle() の down 経路で primary `.keys` && delay set &&
  `!extraDownActions.isEmpty` のとき keyList を組んで postKeysSequence に流し、
  通常の primary dispatch + extras loop を skip。それ以外は現状維持
  (= 挙動非回帰)。single-key + delay は no-op (現状経路)。
- [x] **config.toml** テンプレに例を追記。
- [x] **README.md / README.ja.md** 同期 (bilingual)。
- [x] **Tests**: parse (field 取得 + 非int/≤0 drop) / dispatch routing
  (timing は flaky なので wall-clock でなく「paced 経路に入る」構造を検証)。
- [x] `swift build` + `swift test` green。
- [ ] follow-up issue: cross-key modifier-hold (#130 残り半分) を Inbox に作成。
- [ ] PR (`Closes #130`、残り半分は follow-up issue でトラッキング)。

## 進行ログ

- 2026-06-25: #130 を board In Progress に。delay/hold を読んで delay 半分に絞る判断。
  ActionDispatcher (single .keys post・inline on tap thread)、action-keys 配列が
  primary+extraDownActions に desugar されること、SchemaDescriptor がフィールド権威で
  unknown-key も兼ねること、parseHoldWhileTimeout の drop+warn 規約を確認。実装着手。
- 2026-06-25: 実装完了。Model/parse/schema(input+output)/dispatch/controller/docs を実装。
  per-app は layerableKeys が perAppShape 由来なので自動継承（特別扱い不要と確認）。
  drift guard 連鎖を全て更新: WireBindingDiffCoverageTests.compared + semanticallyEqual +
  ReloadDiffPrinter + ConfigConstraintCoverageTests.notSurfaced + glossary table +
  wire schema enum。`swift test` 400 green。binary smoke test (validate/JSON/bad-drop) +
  warning-kind sync script (24 kinds lockstep) 通過。
  全 checklist 完了。✅ build/test green、commit。

## 未達成・保留

- **cross-key modifier-hold (#130 残り半分)**: この PR では未着手。follow-up issue へ。
- per-app の delay 継承ポリシーは実装中に確定する。

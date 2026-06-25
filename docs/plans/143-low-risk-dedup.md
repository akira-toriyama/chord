# #143 — low-risk dedup (sockaddr_un / JSONEncoder / action-interception)

Closes #143.

`refactor sweep (#122)` で任意・低優先として後回しにした in-repo dedup 3 箇所。
behavior-equivalence の確認が前提なので #122 (dead-code 削除) から分離されている。
branch: `refactor/143-low-risk-dedup`.

## ゴール

3 箇所の重複を **挙動を変えずに** 共通化する。各 site は独立に着手・検証できる。

## 計画チェックリスト

- [x] **Site A — sockaddr_un**: `makeUnixSocketAddr(path:) -> (sockaddr_un, socklen_t)?`
  を ChordApp に新設。`Control.query` (Control.swift:71-86, `connect`) と
  `queryBindListen` (QueryServer.swift:194-209, `bind`) のアドレス構築を置換。
  - 相違は path-too-long ガードの fd 後始末のみ（Control=`defer close`/`return nil`、
    QueryServer=`close(fd); return nil`）→ ヘルパは `nil` を返すだけにし、各 call site が
    自分の fd 後始末を保持する。connect/bind の rebind は call site に残す（差分はそこだけ）。
  - 配置: ChordCore は syscall を持たない純粋層 → ヘルパは **ChordApp** に置く
    (両 consumer が ChordApp)。
- [x] **Site B — JSONEncoder**: `JSONEncoder.chordWire()` を ChordCore に新設
  (`outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`)。
  `BindingsSchema.encodeJSON` (Schema.swift:497-500) と `QuerySchema.encode`
  (QuerySchema.swift:247-250) を置換。各 call site の error 処理は据え置き
  (Schema=`try`、QuerySchema=`try?`+`{}`)。
  - ⚠️ Main.swift:422 は `JSONSerialization` (別 API) → **対象外**。混同しない。
- [x] **Site C — action-interception**: `applyAction(_ action: Action, for binding: Binding) -> (Int, Int)?`
  を Controller に private 新設 (set→store.set / toggle→store.toggle で transition を返す /
  keys・shell・noop→action を載せ替えて ActionDispatcher.dispatch)。
  - `handle(_:)` 下キー switch (Controller.swift:138-155): mutation を applyAction に委譲、
    logging (lifecycleTag / toggle current→next) は call site に残す。
  - `fireBindingAction` (Controller.swift:334-347): body を `applyAction(binding.action, for: binding)` に。
  - `handleKeyUp` on-up (Controller.swift:250-266): `applyAction(onUp, for: binding)` + setVariable の log。
  - ✅ `action-toggle-var-on-up` / `action-hold-var-on-up` は parser 拒否 (Config+Action.swift:145-153/195)
    なので onUp に toggle は来ない → handleKeyUp に toggle 分岐は不要 (gap 無し)。
  - 副産物: 重複していた `fireBindingAction(_:isOnUp:)` を applyAction に畳んで削除
    (`isOnUp` は元から未使用の dead param だった)。modifier-only 2 call site を applyAction に置換。
- [x] `swift build` green
- [x] `swift test` green (393 / 41 suites passed — spine test 5 本含む全緑)
- [x] commit (push は OK 待ち)

## 進行ログ

- 2026-06-25: branch 作成。3 site を独力 + workflow (read-only Explore ×3) で精査。
  sockaddr_un agent の「Control fd leak」指摘は誤り (defer で閉じる) と確認。
  action-interception agent は session limit で落ちたが site は独力精査済み。
  plan 確定、実装着手。

- 2026-06-25: 3 site 実装完了。`swift build` + `swift test` (393 green) 通過。
  spine test (consumedDownPairsItsUpAndPassthroughDoesNot / onUpActionFiresThroughRealPath /
  toggleVariableOnDownFlips / modifierOnlyEntryAndExit / passthroughBindingFiresButDoesNotPair)
  が action-interception の全経路を検証 → behavior-equivalence 確認。ローカル commit。

## 未達成・保留

- **push / PR / merge**: maintainer OK 待ち。merge 後にこの plan file を削除する
  close-out commit を入れる (#148 / #138 と同じ運用)。
- **board #5**: merge / close 後に Status を手動で Done に。

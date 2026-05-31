# chord ユビキタス言語 — Glossary

chord プロジェクトの **正規 (canonical) 用語表**。設計議論・PR レビュー・
コードコメント・ドキュメント全てで、このファイルの用語と表記に従う。

同じ概念を別の名前で呼ぶ揺れ ("alias" だけで input/action のどちらか不明、
"state-store" と "variables" が混在、等) が起きるたびに合意コストが膨らむ。
それを根本的に潰すための辞書。

## 運用ルール

1. **コード変更時に用語を新設 / rename / 意味変更したら、同 PR で本書を更新**
   (PR template の checkbox に従う)。
2. **schema 契約** (`docs/schema/chord.bindings.v1.json`) の enum 値は
   **frozen** とラベル付けし、rename は v2 bump の合図。
3. **英名 = コード識別子と 1:1** を維持。Swift 型は CamelCase、TOML token
   は kebab-case のまま使う。**説明は日本語**。
4. 「**Don't call it:**」欄は **PR レビューでの即時 NG ワード**。コメントで
   指摘するときの根拠にしてよい。

---

## アーキテクチャ層

chord は **CGEventTap (Quartz の上)** に位置する。上下に隣接する層との
関係を最初に視覚化しておく:

```mermaid
flowchart TB
  app["macOS アプリ (Safari / Chrome / VS Code …)"]
  quartz["Quartz / NSEvent layer"]
  tap["CGEventTap (.cgSessionEventTap)"]
  matcher["chord Matcher (ChordCore)"]
  dispatcher["ActionDispatcher (ChordAdapterMacOS)"]
  os_hid["macOS HID 受信 (IOHID)"]
  ble_usb["USB / BLE"]
  zmk["ZMK firmware (canon)"]
  karabiner["Karabiner-Elements (任意)"]

  zmk -->|"HID report"| ble_usb
  ble_usb --> os_hid
  os_hid --> karabiner
  karabiner -->|"DriverKit 仮想 HID"| os_hid
  os_hid --> quartz
  quartz -->|"keyDown / flagsChanged / mouseDown / scroll"| tap
  tap -->|"event"| matcher
  matcher -->|"binding hit"| dispatcher
  dispatcher -->|"再 post (syntheticUserData タグ)"| tap
  tap -->|".passthrough"| app
  app
```

- **ZMK firmware** は chord の上流 (= "atomic chord" emitter)。詳細は §6
- **CGEventTap** は chord の入口かつ出口 (post 後にも再入する)。詳細は §5
- **Matcher** / **Action** / **Binding** は ChordCore の純粋ロジック。詳細は §1

---

## 1. Core types (Swift)

### Modifiers

UInt16 `OptionSet` で表現される修飾キー集合。**2 層構造**:

- **any-side** (`.cmd`, `.opt`, `.ctrl`, `.shift`, `.fn`): L/R 不問
- **strict-side** (`.lcmd`, `.rcmd`, `.lopt`, `.ropt`, `.lctrl`, `.rctrl`,
  `.lshift`, `.rshift`): 片側必須
- **`.hyper`** は `cmd + opt + ctrl + shift` の sugar (any-side のみ)

**Event 側は strict-side ビットのみ運ぶ**。any-side は binding 側にしか
立たない (matcher の `matches(event:)` で柔軟マッチ)。

`isStillHeld(in:)` は `matches(event:)` と別物で、`hold-while`
ライフサイクル用に **余分な修飾を許容**する。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `Modifiers`
- schema: `modifier_token` / `modifier_sides` (frozen)
- **Don't call it**: modifier-mask, modifier-set (説明文の語句としては可、
  概念名としては Modifiers)

### Trigger

binding を発火させる **入力イベントの種別**。代数的データ型:

- `.key(UInt16)` — キーボードのキー (keycode)
- `.mouseButton(MouseButton)` — マウスボタン
- `.scroll(ScrollDirection)` — スクロールホイール方向
- `.anyKey` — wildcard。**[[fallbacks]] でだけ legal**

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `Trigger`
- schema: `trigger.kind` (frozen — §3)
- **Don't call it**: input (config の TOML key と紛らわしい), primary-token

### MouseButton / ScrollDirection

| 型 | 値 |
|---|---|
| `MouseButton` | `left`, `right`, `middle`, `side1`, `side2`, `other5`, `other6`, `other7` |
| `ScrollDirection` | `up`, `down`, `left`, `right` |

`side1` / `side2` は通常マウスの "back" / "forward" ボタンを指す。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift)

### Action

binding が hit したときの **副作用**。

| ケース | 動作 |
|---|---|
| `.keys(Modifiers, UInt16)` | 合成キーイベントを post |
| `.shell(String)` | `/bin/zsh -l -c` でコマンド実行 |
| `.noop` | イベントを吸収するだけ |
| `.setVariable(name, value)` | Controller の state-var を書き換え |

binding は `action` 1 つに加えて **`extraDownActions[]`** を持つ
(v0.4.0+、`action-shell + action-keys` 同時発火)。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `Action`
- schema: `action.kind` (frozen — §3)
- **Don't call it**: action-kind (TOML config の `action-*` プレフィックス
  と混同を招くので、概念名は Action)

### Condition

binding を発火させる **state ゲート述語**。v2 文法は narrow:

- `.variable(name: String, equals: Int)` — 単一変数等価のみ

複雑な式 (`a == 1 && b == 2`) は将来検討 (issue #19)。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `Condition`
- **Don't call it**: state-predicate, when-var-clause

### Binding

trigger + modifiers + optional `apps` → action の **1 行**。
runtime フィールド (`action`, `condition`, `holdWhile`,
`holdWhileTimeoutMs`, `onUpAction`, `extraDownActions`) と
metadata フィールド (`inputRaw`, `actionRaw`, `aliasName`,
`sourceLine`) を持つ。

metadata は **Matcher が無視** し、`--list --json` だけが使う。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `Binding`

### StateSnapshot

Controller の `[String: Int]` 変数ストアの **値型コピー**。tap スレッドが
lock-free に読むため、Event に乗せて渡す。**unset == 0**。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `StateSnapshot`
- **Don't call it**: state-dict, state-store (それは Controller 層の概念)

### ChordConfig / ChordConfig.Options

`config.toml` を読んだ結果の **whole-program 設定**。

```
ChordConfig
├── options          (passthroughUnmatched, excludeApps, fnAutoArrows)
├── bindings         [Binding]
├── fallbacks        [Binding]   ← trigger に .anyKey を許す
├── actionAliases    [String: String]
└── inputAliases     [String: String]
```

`fnAutoArrows` (chord 0.8.0+): true (default) のとき、arrow / nav キー
([KeyCodes.fnAutoNavKeycodes](../Sources/ChordCore/KeyCodes.swift) の 9 key)
の matching で `fn` 比較をスキップする。macOS が arrow に常に
`NSEventModifierFlagFunction` を付与する都合への対応。

- code: [Sources/ChordCore/Models.swift](../Sources/ChordCore/Models.swift) `ChordConfig`

---

## 2. Config concepts (TOML レイヤ)

ユーザが `config.toml` に書くトークン群。全て **frozen** (rename は v2 bump)。

### Sections

| Section | 役割 |
|---|---|
| `[options]` | グローバル設定 (`passthrough-unmatched`, `exclude-apps`) |
| `[[bindings]]` | 通常 binding (document order, first-match-wins) |
| `[[fallbacks]]` | bindings が全 miss した時だけ評価される binding 群。`*` ワイルドカードが許される唯一の場所 |
| `[[sequence]]` | leader-key 用 sugar (chord 0.7.0+)。`prefix` + 子 `[[sequence.bindings]]` + `timeout-ms` から **state-var binding 群に parse 時展開**。詳細は §4 [sequence (leader-key sugar)](#sequence-leader-key-sugar) |
| `[[remap]]` | 1 対 1 リマップ用 sugar (chord 0.8.0+)。`modifiers` + `map = { k1 = "a", k2 = "b" }` から N 個の `.keys` binding に parse 時展開 |
| `[[bindings.per-app]]` | per-OS 分岐 sugar (chord 0.8.0+)。`[[bindings]]` 親に nested AoT で N 個の per-app 子を書き、各子は `apps = [bundle-id]` 付きの binding に展開 |
| `[action-aliases]` | `@name → shell command` の置換テーブル |
| `[input-aliases]` | `$name → "mod1 + mod2"` の置換テーブル |

### Per-binding fields

| Token | 意味 | 備考 |
|---|---|---|
| `input` | trigger + modifiers の文字列表現 | `"$ULTRA_LL - c"` `"mouse.side1"` `"ctrl - scroll.up"` |
| `action-shell` | shell command | `@name` で alias 参照 |
| `action-keys` | 合成キー文字列 | `"cmd + shift - tab"` |
| `action-noop` | true で吸収のみ | |
| `action-set-var` | 書き換える変数名 | |
| `action-set-value` | 書き込む値 (省略時 1, 0 で clear) | |
| `when-var` | 発火を gate する変数名 | 等価値は `when-var-value` (省略時 1) |
| `hold-while` | 修飾保持中だけ var 維持 | `hold-while-timeout` と相互排他 |
| `hold-while-timeout` | inactivity ms 経過で var clear | `hold-while` と相互排他 |
| `action-*-on-up` | 対の key-up で発火する action | `action-keys-on-up` 等 |
| `apps` | bundle id glob 配列 | `["*"]` は nil 扱い、`"!com.example"` で除外 |

### Reference syntax

| 記法 | 意味 | 出現場所 |
|---|---|---|
| `@name` | action-alias 参照 | `action-shell` の値 |
| `@name("arg")` | action-alias 引数付き (issue #26 で実装予定) | `action-shell` の値 |
| `$name` | input-alias 参照 | `input` の値 |
| `*` | wildcard primary key | `[[fallbacks]]` の `input` のみ |
| `keycode-NN` | 生 `CGKeyCode` の脱出口 | `input` / `action-keys` の key 部 |

**Don't call it**:
- `[action-aliases]` ↔ `[input-aliases]` を bare "alias" と呼ばない。**必ず
  "input" / "action" を冠する**。混同が頻発する。
- `[aliases]` (v0.5 までの旧名) は dead — `[action-aliases]` を使う。
- `$prefix` は記法名 (alias 参照の構文) であって概念名ではない。概念名は
  **input-alias**。

---

## 3. Schema enum values (frozen)

`docs/schema/chord.bindings.v1.json` の enum 値。**rename はすべて v2 bump**。
新規追加は forward-compatible (既存 consumer が unknown を許容する前提)。

### `trigger.kind`

| 値 | 意味 |
|---|---|
| `"key"` | キーボードキー (carries keycode) |
| `"mouseButton"` | マウスボタン |
| `"scroll"` | スクロールホイール |
| `"anyKey"` | wildcard ([[fallbacks]] 専用) |

### `action.kind`

| 値 | 意味 |
|---|---|
| `"keys"` | 合成キー post |
| `"shell"` | shell command |
| `"noop"` | 吸収のみ |
| `"set-variable"` | state-var 書き換え (v2+) |

### `modifier_sides`

| 値 | 意味 |
|---|---|
| `"absent"` | 両側 unpressed |
| `"any"` | どちらかの側が held |
| `"left"` | 左側のみ |
| `"right"` | 右側のみ |
| `"both"` | 両側 held |

### `modifier_token`

any-side: `"cmd"`, `"opt"`, `"ctrl"`, `"shift"`, `"fn"`
strict-side: `"lcmd"`, `"rcmd"`, `"lopt"`, `"ropt"`, `"lctrl"`, `"rctrl"`, `"lshift"`, `"rshift"`

### `ConfigWarning.Kind`

| 値 | 発生条件 |
|---|---|
| `"config-not-found"` | config ファイル欠如 (非致命) |
| `"missing-input"` | binding 行に `input` 欠如 |
| `"missing-action"` | binding 行に action-* 欠如 |
| `"unknown-input-token"` | 修飾/キー名の typo |
| `"action-keys-parse-error"` | `action-keys` 文字列パース失敗 |
| `"action-alias-non-string"` | `[action-aliases]` の値が non-string |
| `"undefined-action-alias"` | `@name` が `[action-aliases]` にない |
| `"input-alias-non-string"` | `[input-aliases]` の値が non-string |
| `"input-alias-shadows-modifier"` | alias 名が builtin modifier と衝突 |
| `"input-alias-invalid-body"` | `[input-aliases]` の値がパース不能 |
| `"undefined-input-alias"` | `$name` が `[input-aliases]` にない |
| `"condition-parse-error"` | `when-var` 不正 |
| `"hold-while-parse-error"` | `hold-while` / `hold-while-timeout` 不正 |
| `"action-set-parse-error"` | `action-set-var` / `action-set-value` 不正 |
| `"other"` | 将来の catch-all |

---

## 4. State lifecycle

v2 state machine は **flat `[String: Int]` + 単一変数等価** のみという narrow
な surface。寿命の選択肢は 3 つ:

```mermaid
stateDiagram-v2
  [*] --> Unset: 起動時 / --reload
  Unset --> Set: action-set-var
  Set --> Unset: action-set-value = 0
  Set --> Unset: hold-while の修飾離脱
  Set --> Unset: hold-while-timeout 経過
  Set --> Set: gated binding fire (reset-on-use)
```

### state-var

Controller の `[String: Int]` ストアのエントリ。**unset = 0**。
`Condition.variable(name, equals: 0)` で "mode cleared" を表現するのが
イディオム。書き込みは `action-set-var` (+ `action-set-value`) で行う。

- code: [Sources/ChordApp/Controller.swift](../Sources/ChordApp/Controller.swift) `variables`
- **Don't call it**: variable (一般語で衝突しがち), state-store (Controller 層
  の容器名としては可、概念名としては state-var)

### hold-while-modifier-bound

`hold-while = "cmd + opt"` 形式で **OS の修飾保持に変数寿命を紐づける**。
modifier が全部離れた時点で var が clear される。`Modifiers.isStillHeld(in:)`
は permissive (余分な修飾を許容) なので、shift を追加で押したくらいでは
解除されない。

### hold-while-timeout

`hold-while-timeout = 1500` 形式で **inactivity timer** に変数寿命を紐づける。
gated binding が発火するたびタイマー reset (= **reset-on-use / B-α**)。

ZMK macro が atomic emit する都合で modifier を即座に離す場合、`hold-while`
だと寿命が一瞬で尽きるので、**timeout 系列が canon 用途では実用解**。

### reset-on-use (B-α)

Vim の `timeoutlen` セマンティクス。`when-var` で gate される binding が
発火するたびに `hold-while-timeout` のタイマーが reset される運用。
**chord 0.4.0 で採用**。

### sequence (leader-key sugar)

`[[sequence]]` セクションは **prefix + 子 binding 群 + timeout-ms** を
1 ブロックで宣言し、parse 時に以下の通常 binding 群に展開する (chord 0.7.0+):

- **prefix binding**: `action-set-var = "_seq_<name>"`, `hold-while-timeout = <timeout-ms>` を持つ無条件 binding
- **子 binding**: `when-var = "_seq_<name>"` で gate された binding。`input` は **primary-only** で書き、prefix の modset を自動継承

```toml
[[sequence]]
name = "j-layer"
prefix = "$ULTRA_LL - j"
timeout-ms = 1500

  [[sequence.bindings]]
  input = "k"
  action-keys = "return"

  [[sequence.bindings]]
  input = "l"
  action-keys = "backspace"
```

Matcher / Controller は展開後の binding しか知らない (= 新しい runtime
概念は導入しない)。`_seq_` プレフィックスは **予約済み namespace** で、
ユーザ binding は `action-set-var = "_seq_..."` を書けない (load 時 reject)。

prefix が通常 `[[bindings]]` と `(trigger, modifiers)` 衝突する場合、
**通常 binding が drop され sequence が勝つ** (warning 付き)。

- code: [Sources/ChordCore/Config.swift](../Sources/ChordCore/Config.swift) `parseSequences`
- config: `[[sequence]]` + `[[sequence.bindings]]`
- runtime concept: なし (= ChordConfig.bindings に展開済み)
- **Don't call it**: leader, layer, modal-state (説明文では可、概念名は sequence)

### pendingUps

Controller の `[Trigger: Binding]` テーブル。`B1 contract` (paired
down/up consume) のための内部状態。down を consume したときに登録し、
対応する up が来たら entry を抜き取って `onUpAction` を発火 (あれば)、
up も consume。

**(Trigger, Modifiers) ではなく Trigger だけがキー**。ユーザが down と up
の間に修飾を離す (`cmd` 先に離して `j` を後で離す) ことが多く、event の
modifier mask は down と up で別物になり得るため。

- code: [Sources/ChordApp/Controller.swift](../Sources/ChordApp/Controller.swift) `pendingUps`
- **Don't call it**: pending-releases, up-queue, release-map

### paired down/up consume (B1 contract)

```mermaid
sequenceDiagram
  participant OS as macOS
  participant Tap as CGEventTap callback
  participant Ctrl as Controller
  OS->>Tap: keyDown (j with mods)
  Tap->>Ctrl: handle(event)
  Ctrl->>Ctrl: matcher.find → Binding
  Ctrl->>Ctrl: pendingUps[Trigger] = Binding
  Ctrl-->>Tap: .consume
  Note over OS: keyDown 消失 (OS に届かない)

  OS->>Tap: keyUp (j, mods が違っていても可)
  Tap->>Ctrl: handle(event)
  Ctrl->>Ctrl: pendingUps.removeValue(Trigger)
  alt onUpAction あり
    Ctrl->>Ctrl: dispatch(onUpAction)
  end
  Ctrl-->>Tap: .consume
  Note over OS: keyUp も消失
```

down を飲んだら up も飲む = OS に "phantom key-up" を残さない原則。
**modifier が down と up で食い違っても trigger が一致すれば pair を成立**
させるのがポイント。

---

## 5. Runtime / Adapter

macOS 層に降りた具体実装側の概念。

### CGEventTap

Quartz Core Graphics の event tap。chord は **`.cgSessionEventTap`** に
**head-insert** で取り付ける。mask は `keyDown | keyUp | flagsChanged |
mouseDown 系 | scrollWheel` を含む。

- code: [Sources/ChordAdapterMacOS/EventTap.swift](../Sources/ChordAdapterMacOS/EventTap.swift)
- **Don't call it**: tap-subsystem (具体性なし), event-tap (colloquial、
  文中の語句としてはよいが概念名は CGEventTap)

### syntheticUserData

ActionDispatcher が post する合成イベントに付ける **sentinel 値**
`0x43484F524400` (= ASCII "CHORD\0")。`kCGEventSourceUserData` に書く。
タップが再入時にこの値を見て **自前合成イベントを matcher 投入前に
short-circuit** する。これがないと無限ループ。

- code: [Sources/ChordAdapterMacOS/EventTap.swift:23](../Sources/ChordAdapterMacOS/EventTap.swift) `syntheticUserData`
- **Don't call it**: marker, tag (説明文では可、概念名は syntheticUserData)

### NX_DEVICE bits

`CGEventFlags` の raw value 内に潜む **device-dependent 修飾フラグ**
(L/R 区別)。`0x00000008` = lcmd 等、`IOKit/hidsystem/IOLLEvent.h` 由来。
chord はこれを読んで strict-side ビットを構築する (abstract mask だけ
立っていれば left をデフォルトに丸める)。

- code: [Sources/ChordAdapterMacOS/EventTap.swift](../Sources/ChordAdapterMacOS/EventTap.swift) `readModifiers`

### autorepeat (`kCGKeyboardEventAutorepeat`)

長押し中の連続 key-down を示す CGEvent フィールド。issue #29 でこの取り
扱いを binding 単位の `repeat` プロパティとして公開する予定。

### frontmost

NSWorkspace が報告する **最前面アプリの bundle id**。binding の `apps`
フィルタはこれと glob 比較する。

- code: [Sources/ChordAdapterMacOS/FrontmostTracker.swift](../Sources/ChordAdapterMacOS/FrontmostTracker.swift)
- **Don't call it**: active-app, front-app

### AX permission (Accessibility grant)

CGEventTap が動くのに必須の権限。System Settings → Privacy & Security →
Accessibility で grant。**TCC はコード署名 identity に紐づく**ので、
ad-hoc 署名ではビルドのたびに grant が剥がれる
(`setup-signing-cert.sh` で永続 cert を作るのが対策)。

- code: [Sources/ChordAdapterMacOS/Permissions.swift](../Sources/ChordAdapterMacOS/Permissions.swift)
- **Don't call it**: a11y (colloquial だが説明文では可), accessibility
  (一般語、概念名としては AX permission)

### EventSource

ChordCore と Adapter の seam (シーム) になる **callback ベース** プロトコル。
AsyncStream にしてはいけない (tap callback は同期返却が必須)。

- code: [Sources/ChordCore/EventSource.swift](../Sources/ChordCore/EventSource.swift)
- **Don't call it**: input-source (macOS の IME を指す既存語と衝突, issue
  #30 で別用途で使う)、event-driver

### DNC (Distributed Notification Center)

macOS の IPC チャネル `com.chord.app.control`。client → daemon に reload /
quit / pause / resume を fire-and-forget で送る。**返答経路がない**ので、
daemon 側の status は `/tmp/chord.status` ファイル経由で読む。

- code: [Sources/ChordApp/Control.swift](../Sources/ChordApp/Control.swift)
- **Don't call it**: dnc (略しても可だが正式は DNC)

---

## 6. ZMK / canon side

chord の上流 (= キーボード firmware) で出てくる名前。chord の config の
中にもそのまま現れるので、glossary に載せる。

### canon

ユーザの ZMK firmware リポジトリ
([akira-toriyama/canon](https://github.com/akira-toriyama/canon))。
Cyboard Imprint split keyboard 用。chord 設定の出元 (例: 4 modset の名前は
canon の `eiji_macros.dtsi` に由来)。

### ULTRA_LL / MIRACLE_LM / MEGA_RM / WONDER_RR

ZMK macro 名 4 種。それぞれ右側 3 修飾の異なる組み合わせ:

| Macro | 修飾セット |
|---|---|
| `ULTRA_LL` | `rctrl + ralt + rshift` |
| `MIRACLE_LM` | `rctrl + rcmd + rshift` |
| `MEGA_RM` | `rctrl + rcmd + ralt` |
| `WONDER_RR` | `rcmd + ralt + rshift` |

`private_config.toml` の `[input-aliases]` で論理名化されている。

### atomic chord

ZMK macro 等が **修飾 + primary key を 1 HID report に詰めて発信**する
振る舞い。primary を離した直後に修飾も離れるので、chord 側から見ると
**修飾保持時間が 1-2ms** しかない。`hold-while` ベースの v2 lifecycle が
使えない直接の原因 = `hold-while-timeout` を作る動機。

### F21-F24 (HID 0x70-0x73)

Apple が `kVK_*` 定数を割り当てていないキー。Karabiner / 一部 firmware
remapper の慣習で HID usage `0x70-0x73` に対応する keycode を使う。chord は
これを **受信側のみ** サポート (発信は CGEvent の制約で不能、issue I (skip)
参照)。

### ZMK macro

ZMK firmware で複数 HID 出力を 1 トリガに束ねる仕組み。chord にとっては
"入力源" であって chord 内部の概念ではない (= chord docs で頻出するが
chord 用語ではない)。

---

## 7. CLI / lifecycle

### Standalone subcommands

| Flag | 動作 | Exit code |
|---|---|---|
| `--validate` | config をパース、warning/drop を報告 | 0 / 1 (strict + issues) / 2 (parse error) |
| `--doctor` | validate + AX 権限 + daemon liveness | 0 / 1 (何か NG) |
| `--help` / `--version` | print + exit | 0 |
| `--resign` | brew sandbox 後の Chord.app 再署名 + 再起動 | 0 (署名成功なら) |
| `--watch` | **計画中** (issue #15) — live event trace | — |

### Client subcommands (DNC で daemon と通信)

| Flag | 動作 | Exit code |
|---|---|---|
| `--reload` | config 再読込を要求 | 0 / 3 (no daemon) |
| `--quit` | daemon 停止 | 0 / 3 |
| `--pause` / `--resume` | 全 binding を passthrough に / 復帰 | 0 / 3 |
| `--toggle` | `/tmp/chord.status` を見て pause/resume を反転 | 0 / 3 |
| `--status` | `/tmp/chord.status` の中身を print | 0 / 3 |

### 環境変数

- **`CHORD_DEBUG`** — 設定されると `Log.debugMode = true` で `/tmp/chord.log`
  への書き込みに加え stderr ミラー。`run.sh` が `=1` で設定。brew / raw
  launch ではセットされず静か。

### ファイルパス

| Path | 役割 |
|---|---|
| `/tmp/chord.log` | persistent log。常時書く、CHORD_DEBUG で stderr mirror |
| `/tmp/chord.status` | daemon 状態の逆方向 IPC ファイル (DNC 単方向の補完) |
| `/tmp/chord-loaded.json` | 直近 reload 時の binding スナップショット。`--reload --dry-run` の diff 元 |

### DNC channel

`com.chord.app.control` — Control.swift で `reload` / `quit` / `pause` /
`resume` のいずれかを `name` フィールドに乗せて post。

---

## Entry addition rules

新しい用語を入れたい時の手順:

1. **コード変更 PR と同じ PR でこのファイルを更新する**。後追いしない
   (= PR template の glossary checkbox に該当)
2. 該当 section に追加。section をまたぐ場合 (例: 型 + config token)、
   主たる方に entry を置き、もう一方からはリンクで参照する
3. 既存用語の **rename / 意味変更** は、`Don't call it:` 欄に旧名を追加する
   (= 旧名が CR で再登場することを防ぐ)
4. **schema enum 値** (§3) の rename は、必ず `chord.bindings.v1.json` の
   v2 bump とセットで議論する
5. 新規 entry が `Don't call it:` 持ちなら、**1 件以上 forbidden 同義語を
   挙げる**。「これとは呼ぶな」を明示しないと結局揺れる

### Entry の最小書式

```markdown
### <CanonicalName>

<日本語 1-3 行で定義。必要なら例も>

- code: [path/to/file.swift](../path/to/file.swift) `Symbol`
- schema: `enum_value` (frozen?)
- **Don't call it**: <forbidden synonym 1>, <forbidden synonym 2>
```

`code` / `schema` / `Don't call it` のうち **該当しないものは省略可**。
ただし `Don't call it` を省略する場合は **「同義語の混同がそもそも起きない」
ことを self-review** すること。

---

## 関連ドキュメント

- [docs/non-goals.md](non-goals.md) — chord が **意図的に持たない機能**。
  この glossary に登場しない概念がなぜ登場しないかの説明
- [docs/architecture.md](architecture.md) — 層構造の詳細
- [docs/schema/chord.bindings.v1.json](schema/chord.bindings.v1.json) —
  frozen schema 契約 (このファイルの §3 と相互参照)
- [CLAUDE.md](../CLAUDE.md) — 設計判断と不変条件の出典

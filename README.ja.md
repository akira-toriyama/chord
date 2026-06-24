# chord

macOS 用 グローバルキーボード + マウス ホットキー常駐デーモン。

[English →](./README.md)

```
[ cmd + shift - mouse.side1 ] → 範囲スクリーンショット
[ hyper - f24                ] → "シークレットターミナル" を開く
[ ctrl - scroll.up           ] → VS Code 内でだけズームイン
```

機能:

トリガ:

- **F1 – F24** (F21–F24 は Karabiner 互換 HID スロット経由)
- **マウスボタン**: left / right / middle / side1 / side2
- **スクロール**: up / down / left / right
- **修飾キー連結** + `hyper` 糖衣構文 (= cmd+opt+ctrl+shift)
- **左右別修飾子**: `rctrl` / `lcmd` 等 — ZMK ULTRA_LL のような
  片側専用レイヤを厳密に表現可能
- **修飾子-only triggers** — 主キーなし、bare modifier の
  入/出だけで発火 (chord 0.9.0+)
- **`fn`-auto for arrow / nav キー** — macOS は矢印類に常に `fn` を
  付与するため、`input = "ctrl - right"` がそのまま一致する
- **ベンダー HID「v-key」** — ZMK キーマップが `&vkey <id>` で送出する
  生のベンダーセレクタで発火（専用 HID usage page なので実キーと衝突
  しない）。id を `[v-key-aliases]` で命名し bare `input = "NAME"` で
  バインド。Input Monitoring が必要（[インストール](#インストール)参照）。
  (chord 0.10.0+)

アクション:

- **`action-shell`** — `/bin/zsh -l -c` 経由で実行、`$HOME` 展開可
- **`action-keys`** — 置き換えキーを post
- **`action-keys` 配列** — 1 トリガで複数キーのシーケンス送出
- **`action-shell` + `action-keys` 同時宣言** — shell を fire-
  and-forget して直後にキー post (Karabiner `to`-array 形)
- **`action-noop`** — イベントを食い潰す
- **`action-native`** — `action-mission-control` / `action-
  screenshot` / `action-spotlight` を shell-out なしで実行
- **`action-set-var` / `action-toggle-var` / `action-hold-var`** —
  flat 整数 state machine (単一変数等値のみ、ネストモード無しの
  narrow surface)
- **`action-*-on-up` 系** — リリース時の半分も発火
- **`passthrough = true`** — 発火 AND 元のキーを通過させる
- **`repeat = fire-each | ignore | passthrough`** — autorepeat 戦略

ゲート:

- **`when-var` / `when-vars`** — 単一 + 複数変数 AND 条件
  (leader-key モード等)
- **`hold-while`** / **`hold-while-timeout`** — 変数の寿命を
  修飾子マスク or 非活性タイマに紐づけ
- **`apps = [...]`** — binding 単位の glob 許可リスト + `!` 除外
- **`input-source = "..."`** — macOS の input source / IME /
  キーボードレイアウトでゲート (chord 0.9.0+)

シュガー:

- **`[[fallbacks]]` + `*` ワイルドカード** — modset 単位の「未割当
  キー時にだけ発火」ルール
- **`[[fallbacks]] inputs = [...]`** — 同 action を複数 modset で
  共有するときの 1 行化
- **`[[remap]] map = { … }`** — 1-to-1 修飾子+キー対応の一括宣言
- **`[[sequence]]`** — v2 state-var 上の leader-key 糖衣構文
  (Pattern 9 を手書きする代わりに推奨)
- **`[[bindings.per-app]]`** — 1 トリガから per-OS 分岐
- **`[action-aliases]` + `@name(arg)`** — 繰り返す shell action の
  DRY + `{{N}}` プレースホルダ
- **`[input-aliases]` + `$name`** — 修飾子セットの命名
  (`ULTRA_LL = "rctrl + ralt + rshift"` → `input = "$ULTRA_LL - c"`)

CI / introspection:

- **`chord config --validate [--strict] [--json]`** — parse + lint
- **`chord config --show [--json] [--include-dropped]`** — 現在の parsed config
- **`chord daemon --watch`** — 実イベントのライブ trace
- **`chord config --doctor`** — Accessibility / config / daemon 状態
- **`chord query --status` / `--vars` / `--loaded-bindings` / `--recent-fires`** —
  稼働中デーモンの生状態を JSON で読む (tmux ステータスバー / シェル
  プロンプト / スクリプト向け)

`config --validate` / `config --show` の JSON 出力はバージョン管理された
[`chord.bindings.v3` JSON Schema](docs/schema/chord.bindings.v3.json)
準拠。`chord query` は別系統の `chord.query.v1` wire format
(parsed config ではなく live runtime state) を出力します。

`chord` は Swift 6 製のヘキサゴナル構成 (Core / AdapterMacOS /
AdapterTest / App) で、
[stroke](https://github.com/akira-toriyama/stroke) や
[facet](https://github.com/akira-toriyama/facet) と同型です。
**1 枚の TOML ファイル** だけが挙動を決め、GUI も設定パネルも
永続化された状態もありません。macOS のアクセシビリティ許可は初回のみ
必要です（[v-key](#v-key-vendor-hid-from-zmk) バインドのみ、設定した
ときに限り 2 つ目の許可 — Input Monitoring — が要ります）。

## インストール

macOS 13+ で動作します（最新 macOS 推奨）。

```sh
brew install akira-toriyama/tap/chord

# アクセシビリティ許可が upgrade を跨いで維持されるための初回セットアップ
$(brew --prefix)/share/chord/setup-signing-cert.sh   # chord-dev 識別子作成
chord daemon --resign                                 # 再署名 + 再起動

brew services start chord
```

`brew upgrade chord` のあとは `chord daemon --resign` を 1 回叩いてください。
Homebrew のビルドサンドボックスは login keychain にアクセスできないため
install 時は ad-hoc 署名にフォールバック → そのままだと TCC のアクセシビリティ
許可が upgrade のたびに失われます。`chord daemon --resign` は ad-hoc 署名を持続的な
`chord-dev` 識別子で上書きし、デーモンを再起動するワンステップコマンドです。

ソースからビルドする場合 (Xcode CommandLineTools か Xcode 本体が必要):

```sh
git clone https://github.com/akira-toriyama/chord
cd chord
swift build -c release
./scripts/install-cli.sh        # .build/release/chord → ~/.local/bin/chord
```

Dock 非表示で常駐させたい場合は `./package.sh` で `Chord.app` を組み立て、
`open Chord.app` で起動。初回起動時にアクセシビリティの許可を求めるので、
**システム設定 → プライバシーとセキュリティ → アクセシビリティ** で許可した
あと再起動してください。

**Input Monitoring（v-key 専用）.** 設定に
[v-key](#v-key-vendor-hid-from-zmk) バインド（ZMK キーマップが送出する
ベンダー HID キー）を使う場合のみ、chord はさらに **Input Monitoring**
許可（アクセシビリティとは*別の* TCC 権限）を **システム設定 →
プライバシーとセキュリティ → 入力監視** で必要とします。`Chord.app` は
（ターミナルとは別の）独自のコード署名 identity を持つため、CLI が
アクセシビリティを持っていても GUI デーモンには独自の許可が要ります。
chord は v-key バインドが設定されているときだけ要求し、v-key を使わない
ユーザには一切求めません。`chord config --doctor` の `input monitoring:`
行で状態を確認できます。

## 設定

chord は `~/.config/chord/config.toml` を読みます。テンプレートを取得:

```sh
curl --create-dirs -o ~/.config/chord/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/chord/main/config.toml
```

編集後はデーモンを再起動するか `chord daemon --reload`。ファイル変更を vnode
ウォッチャーで自動検知して再読込もします (vim 等の atomic save / rename
にも対応)。

最小例:

```toml
[options]
passthrough-unmatched = true
exclude-apps = []

[[bindings]]
name = "launch terminal"
input = "f13"
action-shell = "open -a Terminal"

[[bindings]]
name = "screenshot selection"
input = "mouse.side1"
action-keys = "cmd + shift - 4"
```

### 1 回の押下で shell + キー送信

1 つのバインドに `action-shell` と `action-keys` の両方を書くと、
同じキーダウンで「コマンド実行」と「キー送信」を両方行えます
(Karabiner の `to` 配列に相当)。shell が先に発火し
(撃ちっぱなし)、その後キーが送出されるので、フォーカス中の
アプリにもキーが届きます:

```toml
[[bindings]]
name = "facet tree, then nav right"
input = "ctrl - right"
action-shell = "facet --view=tree --loading=2000"
action-keys  = "ctrl - right"
```

元の `ctrl - right` は consume され、再送する方は synthetic タグが
付くのでバインドを再発火しません。組み合わせ可能なのはこのペアの
みで、`action-noop` / `action-set-var` は単一アクションのままです。

### Leader-key モード (v2)

Karabiner 流の 2 ストローク・バインド。リーダーコードでモードを
"装填" し、修飾キーを押したまま次のキーでアクションを発火。修飾を
離した瞬間にモードが自動解除されます:

```toml
[[bindings]]
name = "wm: モード開始"
input = "cmd + opt - j"
action-set-var = "wm"
hold-while = "cmd + opt"

[[bindings]]
name = "wm: 最大化"
input = "cmd + opt - k"
when-var = "wm"
action-shell = "yabai -m window --grid 1:1:0:0:1:1"

[[bindings]]
name = "wm: ダウンで左寄せ / アップで右寄せ"
input = "cmd + opt - l"
when-var = "wm"
action-shell        = "yabai -m window --grid 1:2:0:0:1:1"
action-shell-on-up  = "yabai -m window --grid 1:2:1:0:1:1"
```

`action-set-var` でフラットな整数変数を書込み、`when-var` で gate、
`hold-while` で変数のライフサイクルを修飾マスクに結びつけ、
`action-*-on-up` でキーアップ時のアクションを定義します。
状態表現は意図的に絞ってあり、単一変数の等値比較のみ・モードの
ネストはなし。詳細は [`config.toml`](./config.toml) の Pattern 9
を参照。

### v-key (vendor HID from ZMK)

**v-key** は ZMK キーボードが `&vkey <id>` behavior で送出する生の
ベンダー定義 HID コードです。専用 usage page に乗るので実キーと衝突
しません。chord はこれをキーボードから直接読み（[インストール](#インストール)
の **Input Monitoring** 参照）、他のトリガと同様にルーティングします。

各 id を `[v-key-aliases]` 表で命名し、**bare** `input = "NAME"` で
バインドします（`$` は付けない — v-key alias は `f13` と同様、それ単体で
完結したトリガだからです）:

```toml
[v-key-aliases]
KP_X1   = 0x01
TU_LL_Q = 0x10
TU_LL_C = 0x26

[[bindings]]
name = "v-key: app switcher"
input = "TU_LL_C"        # bare の alias 名 — $ プレフィックス無し
action-shell = "open -a Safari"

[[fallbacks]]
name = "any unassigned v-key beeps"
input = "v-key"          # ワイルドカード: 未割当の全 v-key
action-shell = "afplay /System/Library/Sounds/Tink.aiff"
```

v-key は通常のマッチャを通るので、`apps` / `when-var` / `*-on-up` が
そのまま効きます。id は `1`–`255`、alias 名は大文字小文字を区別しません。
v-key は修飾子を持たないため `[[sequence]]` / `[[remap]]` では使えません
（どちらもトリガに修飾子セットを合成するため）。

chord を [canon](https://github.com/akira-toriyama/canon) キーボードで
駆動する場合、`[v-key-aliases]` ブロックは ZMK キーマップから生成されます
— canon の
[`config/vkey-aliases.toml`](https://github.com/akira-toriyama/canon/blob/main/config/vkey-aliases.toml)
（単一ソースの `scripts/gen-vkey-aliases.py` が生成）からブロックをコピーして
自分の `config.toml` に貼ってください。

全オプションのコメント付きフルテンプレートは [`config.toml`](./config.toml)
を参照。

## CLI

```
chord                       デーモンを起動 (デフォルト)
chord config --validate          config.toml を検証 (エラー0で exit 0)
chord config --validate --strict 警告 / drop が 1 件でもあれば exit 1 (CI 用)
chord config --validate --json   chord.bindings.v3 ドキュメント + validation ブロック
chord config --show              パース結果を人間向けテキストで表示
chord config --show --json       機械向け JSON (chord.bindings.v3)
chord config --show --include-dropped  drop された binding も表示
chord config --doctor            アクセシビリティ / 設定 / デーモンの稼働状況を表示
chord config --emit-schema       config.toml の INPUT JSON Schema (Draft-07) をエディタ補完向けに出力
chord config --observe           押したキーコード / マウスボタン / 修飾の左右をライブ表示
                          (discovery 用・consume しない・Ctrl-C で終了)
chord daemon --resign            Chord.app を chord-dev で再署名 + 再起動
                          (`brew install` / upgrade 後に 1 回)
chord daemon --watch             ライブ per-event trace
                          (/tmp/chord-watch.log で subscribe; Ctrl-C で停止)
chord daemon --reload       稼働中デーモンに設定再読込を指示
chord daemon --reload --dry-run   `--reload` で何が変わるかをプレビュー
chord daemon --quit         稼働中デーモンに終了を指示
chord daemon --pause        全 binding を一時停止（passthrough モード）
chord daemon --resume       binding を再開
chord daemon --toggle       paused ↔ resumed を反転（ホットキー向け）
chord daemon --show         直近のステータス行を表示
chord query --status        live state を JSON で: paused / ax-granted / uptime / config-loaded-at
chord query --vars          現在の state-variable 値を JSON で
chord query --loaded-bindings   binding / fallback / alias の件数を JSON で
chord query --recent-fires [--limit N]   最近 fire した binding（新しい順）を JSON で
chord --help                このテキスト
chord --version             バージョンを表示
```

ログは `/tmp/chord.log`。`CHORD_DEBUG=1` (例: `./run.sh`) で stderr にも
ミラーされます。`--debug` flag は無く、渡すと exit `2`。

## 移行(フラット flag → yabai 式 domain)

deprecation シムは **無い** — 旧フラット flag は exit 2。対応表:

| 旧 | 新 |
| --- | --- |
| `chord --validate` | `chord config --validate` |
| `chord --doctor` | `chord config --doctor` |
| `chord --list` | `chord config --show` |
| `chord --reload` | `chord daemon --reload` |
| `chord --quit` | `chord daemon --quit` |
| `chord --pause` | `chord daemon --pause` |
| `chord --resume` | `chord daemon --resume` |
| `chord --toggle` | `chord daemon --toggle` |
| `chord --status` | `chord daemon --show` |
| `chord --watch` | `chord daemon --watch` |
| `chord --resign` | `chord daemon --resign` |

CLI は yabai 式の domain-verb 文法 (`chord <domain> --<verb> [--mod]`)
になりました。各 domain はちょうど 1 つの verb を取り、verb を組み合わせたり
domain 外の flag を渡すと exit 2 (未知 flag は「did you mean …?」のヒント)。
3 つの domain は `config` (設定; standalone・daemon 不要)、`daemon`
(lifecycle; 稼働中デーモンが必要・無ければ exit 3)、`query` (read-only な
live state を JSON で; 稼働中デーモンが必要・無ければ exit 3)。
exit コードは 0 ok / 1 (`--validate --strict` が tripped) / 2 usage /
3 daemon 未起動。tokenizer は共有 sill CLIKit 製で、chord 固有の verb 語彙を
保持します。

リネームは 2 つ:

- `--list` → `config --show` (config / bindings の一覧)
- `--status` → `daemon --show` (デーモンのランタイム status 行)

`--show` は config / daemon **両方の domain** に存在し別物です — config
内容の一覧は `config --show`、稼働中デーモンの status 行は `daemon --show`。
live runtime state を構造的に読む (現在の state-var 値、最近の fire など)
には `chord query` を使います（DNC でも status file でもない独自の
`chord.query.v1` socket）。

modifier はそのまま引き継ぎます: `config --validate` の `--strict` / `--json`、
`config --show` の `--json` / `--include-dropped`、`daemon --reload` の `--dry-run`。
bare `chord`・`chord --help` / `-h`・`chord --version` / `-V`・`CHORD_DEBUG=1` 環境変数は
影響を受けません。

## アーキテクチャ

```
ChordCore           純粋ロジック — バインディング, TOML, マッチャー, キーコード
ChordAdapterMacOS   CGEventTap / NSWorkspace / CGEvent post
                    (AppKit / CoreGraphics 型を触る唯一のレイヤー)
ChordAdapterTest    統合テスト用の合成 EventSource
ChordApp            実行体 — @main, CLI, Controller, IPC
```

CGEventTap のコールバックは独自のラン・ループ上で動き、**consume か
passthrough を同期的に返さなければならない** ため、`EventSource` の
コンシューマはコールバックから直接呼ばれる closure で、AsyncStream では
ありません。レイヤー規約と非自明な制約の全体は [CLAUDE.md](./CLAUDE.md)
を参照。

## ライセンス

MIT。[LICENSE](./LICENSE) 参照。

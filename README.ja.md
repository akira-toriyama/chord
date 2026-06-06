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

- **`chord --validate [--strict] [--json]`** — parse + lint
- **`chord --list [--json] [--include-dropped]`** — 現在の parsed config
- **`chord --watch`** — 実イベントのライブ trace
- **`chord --doctor`** — Accessibility / config / daemon 状態

`--validate` / `--list` の JSON 出力はバージョン管理された
[`chord.bindings.v3` JSON Schema](docs/schema/chord.bindings.v3.json)
準拠。

`chord` は Swift 6 製のヘキサゴナル構成 (Core / AdapterMacOS /
AdapterTest / App) で、
[stroke](https://github.com/akira-toriyama/stroke) や
[facet](https://github.com/akira-toriyama/facet) と同型です。
**1 枚の TOML ファイル** だけが挙動を決め、GUI も設定パネルも
永続化された状態もありません。macOS のアクセシビリティ許可は初回のみ
必要です。

## インストール

```sh
brew install akira-toriyama/tap/chord

# アクセシビリティ許可が upgrade を跨いで維持されるための初回セットアップ
$(brew --prefix)/share/chord/setup-signing-cert.sh   # chord-dev 識別子作成
chord --resign                                        # 再署名 + 再起動

brew services start chord
```

`brew upgrade chord` のあとは `chord --resign` を 1 回叩いてください。
Homebrew のビルドサンドボックスは login keychain にアクセスできないため
install 時は ad-hoc 署名にフォールバック → そのままだと TCC のアクセシビリティ
許可が upgrade のたびに失われます。`chord --resign` は ad-hoc 署名を持続的な
`chord-dev` 識別子で上書きし、デーモンを再起動するワンステップコマンドです。

ソースからビルドする場合 (macOS 13+ と Xcode CommandLineTools か Xcode 本体が必要):

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

## 設定

chord は `~/.config/chord/config.toml` を読みます。テンプレートを取得:

```sh
curl --create-dirs -o ~/.config/chord/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/chord/main/config.toml
```

編集後はデーモンを再起動するか `chord --reload`。ファイル変更を vnode
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

全オプションのコメント付きフルテンプレートは [`config.toml`](./config.toml)
を参照。

## CLI

```
chord                デーモンを起動 (デフォルト)
chord --validate          config.toml を検証 (エラー0で exit 0)
chord --validate --strict 警告 / drop が 1 件でもあれば exit 1 (CI 用)
chord --validate --json   chord.bindings.v3 ドキュメント + validation ブロック
chord --list              パース結果を人間向けテキストで表示
chord --list --json       機械向け JSON (chord.bindings.v3)
chord --list --include-dropped  drop された binding も表示
chord --doctor            アクセシビリティ / 設定 / デーモンの稼働状況を表示
chord --resign            Chord.app を chord-dev で再署名 + 再起動
                          (`brew install` / upgrade 後に 1 回)
chord --watch             ライブ per-event trace
                          (/tmp/chord-watch.log で subscribe; Ctrl-C で停止)
chord --reload       稼働中デーモンに設定再読込を指示
chord --reload --dry-run   `--reload` で何が変わるかをプレビュー
chord --quit         稼働中デーモンに終了を指示
chord --pause        全 binding を一時停止（passthrough モード）
chord --resume       binding を再開
chord --toggle       paused ↔ resumed を反転（ホットキー向け）
chord --status       直近のステータス行を表示
chord --help         このテキスト
chord --version      バージョンを表示
```

ログは `/tmp/chord.log`。`CHORD_DEBUG=1` (例: `./run.sh`) で stderr にも
ミラーされます。`--debug` flag は無く、渡すと exit `2`。

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

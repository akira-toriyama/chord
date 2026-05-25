# chord

macOS 用 グローバルキーボード + マウス ホットキー常駐デーモン。

[English →](./README.md)

```
[ cmd + shift - mouse.side1 ] → 範囲スクリーンショット
[ hyper - f24                ] → "シークレットターミナル" を開く
[ ctrl - scroll.up           ] → VS Code 内でだけズームイン
```

機能:

- **F1 – F24** (F21–F24 は Karabiner 互換 HID スロット経由)
- **マウスボタン**: left / right / middle / side1 / side2
- **スクロール**: up / down / left / right
- **修飾キー連結** + `hyper` 糖衣構文 (= cmd+opt+ctrl+shift)
- **左右別修飾子**: `rctrl` / `lcmd` 等 — ZMK ULTRA_LL のような
  片側専用レイヤを厳密に表現可能
- **`[[fallbacks]]` + `*` ワイルドカード** — modset 単位の「未割当
  キー時にだけ発火」ルール（効果音フィードバック等）
- **`[aliases]` + `@name`** — 繰り返す shell action の DRY
- **`chord --list --json` / `chord --validate --json`** — CI 消費用、
  バージョン管理された
  [`chord.bindings.v1` JSON Schema](docs/schema/chord.bindings.v1.json)
  準拠

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

全オプションのコメント付きフルテンプレートは [`config.toml`](./config.toml)
を参照。

## CLI

```
chord                デーモンを起動 (デフォルト)
chord --debug        詳細ログ付きでデーモンを起動
chord --validate          config.toml を検証 (エラー0で exit 0)
chord --validate --strict 警告 / drop が 1 件でもあれば exit 1 (CI 用)
chord --validate --json   chord.bindings.v1 ドキュメント + validation ブロック
chord --list              パース結果を人間向けテキストで表示
chord --list --json       機械向け JSON (chord.bindings.v1)
chord --list --include-dropped  drop された binding も表示
chord --doctor            アクセシビリティ / 設定 / デーモンの稼働状況を表示
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

ログは `/tmp/chord.log`。`--debug` 時は stderr にもミラーされます。

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

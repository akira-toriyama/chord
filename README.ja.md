# chord

macOS 用 グローバルキーボード + マウス ホットキー常駐デーモン。

[English →](./README.md)

```
[ cmd + shift - mouse.side1 ] → 範囲スクリーンショット
[ hyper - f24                ] → "シークレットターミナル" を開く
[ ctrl - scroll.up           ] → VS Code 内でだけズームイン
```

`skhd` 系が止まるところから chord が始まります:

| 機能              | skhd / skhd.zig (Carbon) | chord (CGEventTap) |
|-------------------|---------------------------|----------------------|
| F1 – F20          | ✓                          | ✓                    |
| **F21 – F24**     | ✗ (`kVK_*` 未定義)        | ✓                    |
| マウスボタン       | ✗                          | ✓ left/right/middle/side1/side2 |
| スクロール         | ✗                          | ✓ up/down/left/right |
| 修飾キー連結       | ✓                          | ✓ + `hyper` 糖衣構文 |
| **左右別修飾子**   | ✗                          | ✓ `rctrl` / `lcmd` 等 (ZMK ULTRA_LL 対応) |
| アクセシビリティ   | 不要                       | 必要 (初回のみ)      |

`chord` は Swift 6 製のヘキサゴナル構成 (Core / AdapterMacOS /
AdapterTest / App) で、
[stroke](https://github.com/akira-toriyama/stroke) や
[facet](https://github.com/akira-toriyama/facet) と同型です。
**1 枚の TOML ファイル** だけが挙動を決め、GUI も設定パネルも
永続化された状態もありません。

## ステータス

⚠️ 1.0 未満です。Homebrew 配布はまだ。ソースからビルドしてください。

## インストール (ソースから)

macOS 13+ と Xcode CommandLineTools (または Xcode 本体) が必要です。

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
chord --doctor            アクセシビリティ / 設定 / デーモンの稼働状況を表示
chord --reload       稼働中デーモンに設定再読込を指示
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

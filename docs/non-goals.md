# Non-Goals

chord が **意図的に持たない機能** と、その理由を記録する。隣接プロジェクト
([skhd](https://github.com/koekeishiya/skhd) /
[skhd.zig](https://github.com/jackielii/skhd.zig) /
[Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements) /
[ZMK](https://github.com/zmkfirmware/zmk)) の調査時に検討対象としたが、
chord の設計思想・配布性・USP を踏まえて採用しないと判断したものを並べる。

issue を立てない代わりにここに残すことで、同じ議論が定期的に再燃するのを防ぐ。

## chord の USP (これを守るために non-goal を持つ)

- **AX 1 つで動く軽さ**: Accessibility 権限だけで全機能が動く。DriverKit
  / IOHIDManager / 仮想 HID デバイス / root daemon を要求しない。
- **CGEventTap 1 段の単純さ**: 同期 first-match-wins。tap callback 内で
  consume / pass を即決する契約。
- **TOML 一本の人間可読 config**: GUI なし、自動生成なし、`config.toml`
  が唯一の真実。
- **narrow surface の state machine**: 単一変数等価のみ、ネストモードなし。
  複雑な状態は ZMK / Karabiner にまかせる。

これらに反するものは **どんなに人気があっても non-goal**。

---

## 1. mod-morph (修飾の有無で動作変化)

*(reviewed 2026-05-31)*

**出元**: ZMK `&mm` (mod-morph)

ZMK のような HID 層の remapper では「`;` 単体 → `;` / shift+`;` → `:`」
のように 1 物理キーの動作を修飾の有無で morph する機能が頻出する。HID 層
では modifier transparency を扱う都合があるからだ。

**chord では不要**。chord は CGEventTap 層で動き、**OS が既に修飾を解釈済み
の状態でイベントを受け取る**。`shift + semicolon` を打てば OS のキーマップ
が `:` を生成し、それが chord のトリガになる。同じことを実現するには:

```toml
[[bindings]] input = "semicolon"           action-keys = "..."
[[bindings]] input = "shift - semicolon"   action-keys = "..."
```

を別 binding として書けばよい。`[[remap]]` (#13) で表形式 DRY も可能。
mod-morph という独立機能を入れる純粋な利得が薄い。

---

## 2. per-device (VID/PID) マッチ

*(reviewed 2026-05-31)*

**出元**: [skhd.zig `.device`](https://github.com/jackielii/skhd.zig),
[Karabiner `device_if`](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/device/)

「内蔵キーボードでは発火させず canon (ZMK) だけで動かす」のような VID/PID
ベースの分岐は **chord のアーキでは原理的に取れない**:

- CGEventTap には `kCGKeyboardEventKeyboardType` (HID country code) と
  eventSource ID 程度しか乗らず、物理デバイスの identity は剥がれている
- 取得するには **IOHIDManager に独立で購読** + Karabiner 風の HID/CGEvent
  突合、もしくは DriverKit 仮想 HID 経由が必要
- どちらも **chord の最大 USP「AX 1 つで動く軽さ」を喪失** する

実害面でも、ULTRA_LL のような 3 修飾 strict-side chord は内蔵キーボードで
**物理的に押せない**可能性が高く、誤発火率がそもそも未確認。

**必要になったら**: Karabiner-Elements を併用する (Karabiner で per-device
filter → chord で routing) のが正しい役割分担。

---

## 3. dead-key / F21-F24 origination (chord 側で発信)

*(reviewed 2026-05-31)*

**出元**: [Karabiner-Elements](https://karabiner-elements.pqrs.org/) の
DriverKit 仮想 HID デバイス

chord は F21-F24 / dead-key / consumer page キーを **解釈** (受信側) はでき
るが、**発信** (CGEvent.post) はできない:

- F21-F24 は Apple が `kVK_*` 定数を未割り当て。CGEvent では未定義 keycode 扱い
- Dead-key は OS のキーマップ層で合成されるため、CGEvent では合成後の文字
  しか流せない
- Consumer page (媒体キー等) は一部 `NSEvent` 経由で可能だが、ホットキー
  発信のユースが薄い

実装するには Karabiner-VirtualHIDDevice-Daemon への IPC が必要で、これは
DriverKit 依存 = chord の USP 喪失。

**ユースケースが先**: そもそも chord が F21-F24 を発信する場面が具体的に
想像できない (canon は ZMK が emit する側、chord は受け側、という役割が
固まっている)。

**必要になったら**: Karabiner-Elements を併用 (Karabiner で HID 発信 →
chord で routing)。

---

## 4. BLE / multi-host pairing

*(reviewed 2026-05-31)*

**出元**: [ZMK Bluetooth subsystem](https://zmk.dev/docs/features/bluetooth)
(`&bt BT_SEL N` 等)

ZMK firmware の機能領域。chord は **macOS の userland daemon** であり、
原理的に関与不能:

- BLE ペアリング状態は **キーボード MCU の中**にある
- ホスト切替 = macOS から見ると一旦切断 + 別ホストへ繋ぎ直し = 切替後の
  ホストでは chord は別 OS のインスタンス
- 制御権が macOS 側にない

副次的に「BLE 切断検知して自動 pause」程度の周辺機能は考えうるが、それは
`chord --watch` (#15) や `chord --status` の拡張で済み、独立 issue にする
規模ではない。

---

## 5. JSON config format (Karabiner 風)

*(reviewed 2026-05-31)*

**出元**: [Karabiner-Elements `karabiner.json`](https://karabiner-elements.pqrs.org/docs/manual/configuration/configuration-file-path/)

chord は TOML 一本で十分。JSON 入力サポートを追加する利得が薄い:

- **意味論差で Karabiner JSON は流用不可**: Karabiner の
  `complex_modifications.rules[].manipulators[].from/to/conditions[]` と
  chord の `[[bindings]]` 構造は別物。形だけ JSON 化してもコンバートは別途必要
- **TOML の人間可読性が chord 文化の一部**:
  [private_config.toml](https://github.com/akira-toriyama/dotfiles/blob/main/chezmoi/dot_config/chord/private_config.toml)
  のコメント密度・`[input-aliases]` / `[action-aliases]` の表形式が chord DSL
  の見やすさの支柱
- **2 系統メンテのコスト**: 新機能 (`[[sequence]]` / `per-app` / `{{N}}`)
  すべてで TOML + JSON 両対応コードを書く負債
- **`--list --json` は既に存在**: 機械 read 用途は出力側で網羅されている

**機械生成したいなら**: Python `tomlkit` / Swift `TOMLKit` 等で TOML を
書き出せばよい。入力側の JSON サポートは不要。

---

## When these become Yes

各 non-goal が **採用検討に値する状況になる条件**:

| Non-goal | Yes になる条件 |
|---|---|
| 1. mod-morph | chord が HID 層 (DriverKit) に降りる決定が別途されたとき |
| 2. per-device | 上記 + 「内蔵キーボードでの誤発火」が複数ユーザから具体的に報告されたとき |
| 3. dead-key origination | chord 側から F21-F24 等を発信する具体的ユースケースが現れたとき |
| 4. BLE | (原理的に不可。再検討の余地なし) |
| 5. JSON config | TOML パーサが致命的なエッジケースで詰まり、JSON への乗り換えが TOML 修正より小さくなったとき |

いずれも **「USP を犠牲にしても得たい何か」が具体的に存在する** のが前提。
抽象的な「あれば便利」では再検討しない。

---

## References

- [skhd 調査メモ](https://github.com/akira-toriyama/chord/issues) — 機能比較は CLAUDE.md References セクションを参照
- [Karabiner-Elements complex_modifications](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/)
- [ZMK behaviors](https://zmk.dev/docs/keymaps/behaviors)

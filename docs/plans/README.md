# docs/plans/

進行中の作業の**細粒度な計画 + 進行状況**を、1 作業 1 ファイルで
管理する場所。運用ルールは
[CLAUDE.md → 作業方針 (multi-session work policy)](../../CLAUDE.md)
を正とする。

- **1 作業 = 1 ファイル**: `<#issue>-<slug>.md` (例:
  `71-leader-key-timeout.md`)。
- **ここが進行状況の唯一の真実**。GitHub Projects とは粒度で
  棲み分ける (Projects = 高レベルな issue / milestone、ここ =
  その実装の細粒度な計画 + 進行ログ)。同じ情報を二重に持たない。
- **未達成を暗黙にしない**。積み残し・保留は plan file に明示的に
  残す。「別途やる」ものは issue 化して Projects Inbox へ。
- **ライフサイクル**: 未達成が残る限りファイルを置く。全完了したら
  削除 (履歴は git に残る) し、issue を Done へ。
- **不変条件**: このディレクトリに README 以外のファイルが無い =
  進行中の積み残しなし。

## テンプレート

新しい作業を始めるときはこれをコピーする:

```markdown
# <作業タイトル>

- Issue: Closes #N
- Status: planning | in-progress | blocked | done
- Updated: YYYY-MM-DD

## ゴール
<何が達成されたら完了か。完了条件を 1〜数行で>

## 計画 (plan)
- [ ] ステップ 1
- [ ] ステップ 2

## 進行ログ (execute)
- YYYY-MM-DD: <何をやったか / 次の一手>

## 未達成・保留
- [ ] <積み残し。暗黙に消さない。別途やるものは issue 化して Inbox へ>
```

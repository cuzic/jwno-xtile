# 0003. AI 支援開発のワークフローと検証の強制方法

- 状態: Accepted（Opus レビュー収束＋Stop フック設定済み、2026-10-31。Shell の検証 8 は Shell 実装時）
- 日付: 2026-10-31

## Context

コードの大半を AI エージェント（Claude Code）が書く。調査で繰り返し出てくる失敗は、
(a) 「完了に見えた」時点で止まる、(b) 指示ファイルが肥大して無視される、(c) 守らせたい
ルールをプロンプトに書いて取りこぼす。Core が純粋なので、検証を機械化しやすい。

**この ADR 自身の反例**: 最初の実装は「xmonad セマンティクス」を謳いながら `insertUp` と
`swapMaster` が xmonad と違い（`shiftMaster` の動作）、エージェントが書いた例示テストが
その誤りを仕様として固定していた。テストが通っても、同じエージェントが書いたテストは
独立した検証にならない。発見したのは別セッションの批判的レビューと一次情報の確認だった。
以下の決定は、この種の失敗を前提に組み立てる。

## Decision

1. **完了 = `mise run test` が通ること**。【`mise run test` と Stop／SubagentStop フック（`.claude/settings.json`, `scripts/stop-check.sh`）は設定済み。スクリプトは単体で動作確認済み（失敗で exit 2、成功で 0、`stop_hook_active` で 0）。ハーネスが実際にブロックするかは次のセッションで確認する】エージェントが叩ける 1 コマンドの検査を持ち、
   Stop フックで強制する。例外なく守らせたいルールはフック、好みは CLAUDE.md（公式の区別）。
   Stop フックの運用: `stop_hook_active` を見て無限ループを避ける／サブエージェント用に
   SubagentStop も設定／コマンドは `mise exec -- ...` で PATH 非依存にする／議論だけの
   ターンで毎回テストが走る（約 4 秒）ことは許容する。
2. 【`docs/INVARIANTS.md` は Draft で実装済み／人間の承認は **未了**】**仕様は人間が承認した不変条件に置く**: `docs/INVARIANTS.md`（現在は Draft）が仕様で、
   プロパティテストはその ID を参照する。承認前の不変条件は「エージェント案」と明記する。
3. 【実装済み】**独立した参照モデルと差分テスト**: xmonad の StackSet を別の形（zipper）で一次情報
   から転記した `test/xmonad-model.janet` と、`src/core/workspace` の差分テストを行う。
   「同じ誤解を共有する」問題に対する、独立性の担保手段。
4. 【実装済み】**テストは層別**: 例示テスト（期待値固定）＋プロパティ＋差分。バグ修正は再現テストを先に。
   カバレッジは未計測であり、テスト件数を網羅性の根拠にしない。
5. 【運用中】**小さな単位で進める**: 1 変更 = 1 つの振る舞い。非自明な設計判断は実装前に ADR（Proposed）
   を書き、別モデル／独立コンテキストの批判的レビュー（Opus）を通して収束してから Accepted にする。
6. 【実装済み（短い CLAUDE.md あり）】**CLAUDE.md は短く**（目安 200 行未満）。コマンド、構造規則、ADR への参照、
   読んではいけないもの（tall）のみ。エージェントが実際に間違えた点を足していく。
7. 【実装済み】**構造規則の機械検査**: `src/core` の純粋性は `test/purity-test.janet`（許可リスト式 import
   ＋非純粋シンボルの禁止）。grep だけの検査は `(os/time)` 等をすり抜けるので採らない。
8. 【Shell 自体が **未実装**。依存注入・フェイク・契約テスト・チェックリストはすべて未着手】**Shell の検証は 3 段**（Shell は `jwno/context` を注入できる構造にし Linux でもロード可）:
   1. フェイク Jwno で、イベント変換と effect 実行のマッピングを検査（Linux）。
   2. Jwno の実物を使う契約テスト（フックの発火条件など「自分が想像した API」を潰す）。
      Windows で実行する（GCP の Windows spot runner か手動）。
   3. 手動の実機チェックリスト（`docs/`）。
   Shell を変更したときの「完了」は、段 2〜3 を実行済みか、「Windows 未検証」ラベル付き。

9. 【実施済み】**例外を許さない禁止事項は、強制手段を CLAUDE.md の注意書きに頼らない**:
   「GPL の `jwno-layout-tall` を読まない」（ADR 0002）は、ユーザー判断で **checkout 自体を削除**
   して強制した（2026-10-31）。再度 clone しない。必要になったら作者の README を読む。

## Considered Options

- A. 上記。
- B. CLAUDE.md の指示だけに頼る。→ 取りこぼす。公式も例外なきルールはフックとしている。
- C. LLM に網羅的な例示テストを大量生成させる。→ 実装と同じ誤解を共有する（上の反例）。

## Consequences

- 良い: 完了条件が機械的。Core は Linux で全検証でき、独立モデルで意味的な誤りも拾える。
- 悪い: 不変条件の承認は人間の仕事で、未承認なら偽の安心を生む（INVARIANTS.md は Draft）。
- 悪い: Shell と実機挙動は Linux の自動検証の外にある。ここが最大の残余リスク。
- 悪い: フェイクのテストは「想像した API」に対するテストにすぎない。契約テストが必須。

## Evidence（出典・取得日 2026-10-31・信頼度）

- 一次（取得して該当節を確認）: Anthropic, "Best practices for Claude Code",
  https://code.claude.com/docs/en/best-practices —
  「Give Claude a check to run」「Enforce the check with a Stop hook」「If something has to
  happen every time, make it a hook, a deny rule, or a managed setting. CLAUDE.md is for
  guidelines」「Keep CLAUDE.md short」。
- 二次（ブログ・ガイド、公式未確認）: CLAUDE.md/AGENTS.md は 200 行未満・推測できる内容は書かない
  （例: https://www.openhands.dev/blog/claude-code-best-practices-agentic-coding ほか）、
  ADR を MADR で書き AGENTS.md から参照させる（https://codex.danielvaughan.com/ 2026-04-28）。
- 学術: He et al., "Use Property-Based Testing to Bridge LLM Code Generation and Validation"
  (arXiv 2506.18315) — PBT を検証ループに使うと関数単位ベンチマークで改善と報告。
  arXiv 2510.25297 はエッジケースの例示テストと PBT の比較（題名は未確認）。
  いずれも関数単位のベンチマークで、本プロジェクトの状態機械には直接の保証がない。
- 未確認: Claude Code が AGENTS.md を自動で読むか（情報源が矛盾）。CLAUDE.md を正とするので影響しない。
- 見つからなかった: FCIS を AI 生成コードの構造化に使う利点を直接扱った資料。
  「FCIS が AI 開発に向く」は一般的推論であり、実証された事実ではない。

## Confirmation

- 【達成】Stop フック（ループ防止・SubagentStop 込み）が設定されている。次のセッションで、テストを壊したときにターンが実際にブロックされることを確認する。
- INVARIANTS.md が人間に承認されるまで Status を Draft のままにすること。
- CLAUDE.md が 200 行未満。

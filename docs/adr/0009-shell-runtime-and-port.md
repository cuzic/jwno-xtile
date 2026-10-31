# 0009. Shell は「ポート越しの実行系」と「Jwno アダプタ」に分け、前者を先に作る

- 状態: Accepted（Opus レビュー 2 回で収束、2026-10-31。runtime とフェイクのテストは実装済み。Jwno アダプタは未実装、Windows 未検証）
- 日付: 2026-10-31

## Context

ADR 0001/0005 は Shell の規約（state を保存してから effect を実行／再入禁止のキュー／`protect`／
実行後と desktop-changed 後の再観測／破壊的コマンド直前の再観測／`:close` 実行直前の確認／起動時の
列挙）を定めたが、Shell の構造と OS との境界の形は未定だった。Jwno の実物に触れるコードは Windows でしか
検証できず（ADR 0003 §8）、Linux で書けるのは「想像した API に対するコード」になる。

## Considered Options

1. Jwno の `context` を直接受け取る Shell を一枚で書く。→ 規約（キュー・再観測など）と Jwno の
   API 形状が混ざり、フェイクで検証できる範囲が曖昧になる。
2. **規約を実装する実行系（runtime）と、OS 境界の「ポート」`ctx` を分ける。** runtime はポートだけを
   知り、Jwno も jw32 も import しない。Jwno アダプタは別ファイルでポートを実装する。
3. Core に Shell 規約を取り込む。→ ADR 0001 に反する（OS 境界の分岐は Shell）。

## Decision

案 2。`src/shell/runtime.janet`（Linux でロード・テスト可）と、後続の `src/shell/jwno.janet`
（アダプタ。**今回は作らない**。契約テストとセットで作る）。

### ポート `ctx`（dictionary of function。すべて OS 境界）
- 実行: `:place (id rect)` `:focus (id)` `:close (id)` `:goto (tag)` `:send (id tag)`。
- 観測: `:foreground () -> id|nil` は **正規化しない**トップレベルの hwnd（`GA_ROOT`。所有者へ寄せない）。
  ADR 0008 で owned ダイアログが管理対象のフロートになったため、所有者へ寄せると「ダイアログを見ているのに
  所有者を close」になる（レビュー H1）。`:foreground-is? (id) -> bool` は **完全一致**。
  ADR 0005 §3-7-2 の「またはそれが所有するウィンドウ」は **この ADR で改訂**する。
  `:current-desktop () -> tag|nil`（OS が今いるデスクトップ。`:goto` の失敗の回復に使う）、
  `:enumerate () -> [[id tag-or-nil facts] ...]`（最前面から順。facts は ADR 0008 の `classify` の
  facts と同じスキーマ。非表示は含めても含めなくてもよい＝どちらでも hidden の除去と同じ結果）。
  `:work-area () -> rect`（**単一モニタ**。マルチモニタは範囲外）。
- その他: `:later (delay-seconds thunk)`（`dispatch` と同じスレッドから呼ぶこと。契約）、
  `:log (level message)`、`:notify (kind id)`。thunk は **処理する時点で** `foreground`/`enumerate` を評価する。
- どのポート関数も投げうる。runtime は `protect` で囲む（`:log` も）。

### runtime の規約（ADR 0005 §3 の実装）
`(make ctx &opt state) -> rt`、`(dispatch rt event)`、`(start rt)`、`(state rt)`。
- **R-1 キュー**: `dispatch` は event を積み、実行中（busy）なら戻る。drain は
  `(defer (set busy false) (while queue ...))`。effect やログの中からの `dispatch` は積むだけ（再入禁止）。
  busy は例外が出ても必ず戻る（M3）。
- **R-2 保存してから実行**: `update` の結果の state を保存した後で effects を順に実行する。
- **R-3 `protect`**: `update` が投げたら state を変えずログに残し、次へ進む。effect が投げても残りを
  続ける。**ただし `:goto` が失敗したら同じバッチの `:focus` は実行しない**（M4。他デスクトップの窓へ
  フォーカスを送らない）。`:place` は続ける。
- **R-4 事後の再観測**: バッチの effect を **すべて実行した後に 1 回**（L1）、そのバッチに `:focus`／`:goto` が
  あったとき、および `:desktop-changed` を処理した後に、`foreground` を読み、**非 nil のときだけ**
  `[:focus-changed id]` をキューの先頭に積む（nil は「観測なし」。切替途中の一瞬の nil で正しい
  `:os-focus` を消さない。M2）。加えて `:later` で短い遅延（100〜300ms）の後にもう 1 回同じ再観測を
  積む（直後の読み取りは古いことがある。M1）。この遅延再観測は同時に 1 つまで（予約中の要求は捨てる。thunk は処理時に評価するので問題ない）、
  回復（R-8）とは別枠。
- **R-5 command の直前**: **すべての `:command`** の処理直前に、`foreground` を読み、**nil も含めて**
  `[:focus-changed (foreground)]` を **同じ処理の中で先に** `update` へ流す（キューの逆順を避ける）。
  nil を流すのは安全側（actionable が落ち、破壊的操作が止まる）。Core の破壊的コマンド一覧を
  Shell に二重管理しないため、全 command を対象にする（M6）。
- **R-6 `:close` の直前確認**: `:close id` の実行直前に `(foreground-is? id)` を確かめ、偽なら実行せず
  `notify :ignored-close` とログ。`:send` は確認しない（データを失わないので意図的。L4）。
- **R-7 起動**: アダプタは **フックを先に登録**し、`start` は busy のまま `[:screen-changed (work-area)]`、
  `[:windows-observed (enumerate)]`、再観測を処理し、その間に溜まった event を drain する（取りこぼし防止。
  重複は冪等性が吸収。M5）。
- **R-8 失敗の回復**: バッチの effect が 1 つでも投げたら、`:later`（**1 秒**。R-4 の遅延再観測より長くし、ユーザー操作と
  競合しない）で、`[:desktop-changed (current-desktop)]`（nil なら省く。`:goto` の失敗で Core の
  `:current` が OS より先に進んだままになるのを直す。Core の `desktop-changed` は冪等）、
  `[:windows-observed (enumerate)]`、`[:command :refresh]` を順に積む。予約は同時に 1 つまで。**失敗カウンタ**は回復の予約ごとに +1 で、
  3 に達したら予約しない。カウンタを 0 に戻すのは「**effect を 1 つ以上実行し、すべて成功した
  バッチ**」だけ（effect の無い silent event では戻さない。永続的に失敗する effect に対して定期的な
  回復が永遠に続くのを防ぐ。H2）。失敗を Core の観測イベント（`[:effect-failed ...]`）にするかは
  ADR 0005 §2 の未決のまま。
- **R-9 `:window-moved`** はそのまま通す。矩形の座標系の正規化（DWM の枠）とドラッグ中を流さない
  ことはアダプタの責務（Windows 未検証）。

## Consequences
- 良い: ADR 0005 §3 の規約が Linux のフェイクで検査できる。アダプタは「ポートの実装」だけになり、
  Jwno 変更の影響面積が小さい。
- 悪い: ポートの形（特に `:enumerate` の facts、`:foreground` の所有者正規化）は **想像した API**。
  実物に合うかは契約テストまで未検証。**Windows 未検証**。
- 悪い: R-4 の再観測は、`foreground` が不安定な環境で `focus-changed` の往復を増やす。silent なので
  効果は出ないが、頻度は実機で見直す。

## 未決事項（スパイクで判明、2026-10-31。実機でも要確認）
- **`:goto` の直後の `:focus` は Jwno に上書きされる**（`docs/spike/2026-10-31-hosted-windows.md`）。
  緩和策を比較実験した（各 n=10、ホスト型 Windows Server 2022。実機ではない）:

  | 案 | 内容 | 成功 | 着地 | 欠点 |
  |---|---|---|---|---|
  | なし | 切替直後に `:focus` | 0/10 | 3ms | 毎回 B に戻される |
  | A | アダプタが Jwno の `set-focus-to-hwnd` を握りつぶす | 10/10 | 4ms | Jwno 内部との結合。Jwno の版に依存。他の用途の focus も止まる |
  | B | `:goto` の後 150/250/500ms 待って `:focus` | 10/10 | 156/265/516ms | 待つ間 Jwno の選んだ窓が前面に見える。遅延は負荷依存 |
  | C | 即 `:focus`、250ms 後に不一致なら 1 回再発行 | 10/10 | 4ms（点滅後 ~280ms） | **毎回 C→B→C と点滅**する |

  **暫定の推奨（未決定。ADR の改訂とレビューを経てから実装）**: A を主、C を保険にする。A で競合を消し、
  それでも前面がモデルと食い違う場合（フォアグラウンドロックなど）は、R-4 の遅延再観測が 1 回だけ `:focus`
  を再発行する（上限 1 回）。Jwno への結合を避けたい場合は B250 + C に倒す。いずれも、実機（Windows 10/11）で
  同じ傾向かを確かめてから確定する。A を採るなら、Jwno の版を固定し、契約テストで「ラップが効いている」ことを検査する。
- `:focus` を別デスクトップの窓へ出すと暗黙の `:goto` になる。Core が `:goto` を先に出す現在の順序は
  維持してよいが、`:send` 直後や `windows-observed` 後に他デスクトップの窓へ `:focus` が出ないことを
  Core のプロパティとして検査する余地がある（E2 の拡張）。

## Confirmation
- フェイクポートのテスト（RT-1〜RT-9）: RT-1 再入しない・drain 完了／RT-2 保存が先／RT-3 `:close` は
  フェイク OS のフォアグラウンドと完全一致のときだけ（owned ダイアログ回帰）／RT-4 到着順・欠落を
  ランダムにしても真のフォアグラウンド以外を close しない／RT-5 失敗を含むバッチ 1 つから連鎖する回復は 3 回まで（成功したバッチを挟まない限り再予約しない）／RT-6 ポートが投げても
  次の dispatch が処理される／RT-7 再観測は連鎖せず注入数に上限／RT-8 起動中に届いた event も入る／
  RT-9（`:goto` の失敗を含む）通知を遅延・重複・欠落させても、通知が止まった後に refresh と観測でモデルと OS が一致。特に「close キーとフォーカス通知を逆順に届けても誤 close
  しない」（ADR 0005 Confirmation）、effect が投げても state が保存済み、再入しない、回復が有限回で止まる。
- 実装前に Opus レビュー。アダプタは別 ADR/タスクで契約テストと共に。

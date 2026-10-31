# 0009. Shell は「ポート越しの実行系」と「Jwno アダプタ」に分け、前者を先に作る

- 状態: Accepted（改訂 5: 緩和策は A を主・C を補助とする暫定の決定。Opus レビュー 4 回で収束、2026-10-31。runtime（R-10 を含む）と Core の `:pending-focus`/`:reassert-focus` は実装済みで、フェイク OS とプロパティで検査済み。Jwno アダプタ（A-1〜A-4）は未実装。Windows 未検証）
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
  **`[:desktop-changed (current-desktop)]`（tag が引ければ。ADR 0010 N1: Core の `:current` を OS に合わせる）**、
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
- **R-10 `:goto` の後の遅延 `:reassert-focus`（案 C）**。バッチの effect を実行し終えたとき、`:goto` と `:focus`
  が**どちらも成功していれば**（失敗した `:goto` では何もしない。R-3）、`:later`（250ms）で
  `[:command :reassert-focus]`（引数なし）を `dispatch` する。予約は毎回行う（後勝ち。古いタイマーが残っても、引数なしの command は pending が無ければ無害な no-op）。判断はすべて Core にあり
  （下記）、Shell は「いつ問い合わせるか」だけを持つ。Core が何もしない状況（pending が無い等）では無害な no-op。
  アダプタは設定 `:reassert?`（既定 true）で R-10 を切れる（A のみ運用に切り替えるための 1 行のスイッチ）。

### Core の state `:pending-focus` と内部コマンド `:reassert-focus`
- `:pending-focus {:target id :tag tag}` は Core の state（不変データ。無ければキー無し）。`:goto` コマンドが
  `[:focus f]` を出すとき（= 切替先に窓がある）、`{:target f :tag 切替先のタグ}` を立てる。
- 下ろす条件（いずれか）: **`:reassert-focus` 以外の任意の `:command`**（ユーザーの意図が変わった）／`target` への
  `focus-changed`（成功）／`target` が閉じられた・hidden／`:current` が `:tag` と違う（ユーザーが手でデスクトップを
  切り替えた）／**Core 自身が非 silent な event（`window-opened`・`window-seen`・`window-closed` など）で可視ワークスペースの
  フォーカスを動かした**（新しい窓にフォーカスを与えた判断を古い意図で取り消さない。silent な観測 `focus-changed` では
  下ろさない: Jwno の上書きを観測してもなお C を補うため）／`:reassert-focus` が受理された（**1 エピソードにつき再発行は構造的に最大 1 回**）。
- `[:command :reassert-focus]`（束縛不可。`command-args` で `:internal`）: `:pending-focus` があり、`target` が可視
  ワークスペースの管理ウィンドウで、**`:external-focus` が偽**（管理外のウィンドウからは奪わない）で、
  **`:os-focus` がフロート（`:floating`）でなく**（ADR 0008 で owned ダイアログは管理下のフロート。応答すべき
  ダイアログを裏に回さない）、`:os-focus ≠ target` のときだけ、モデルのフォーカスを `target` にして
  `[:focus target]` を出し、`:pending-focus` を下ろす。それ以外は何もしない（pending は条件次第で残る）。
  引数は取らない（`:os-focus` は R-5 の直前観測で最新。引数を足すと情報源が二つになる）。引数が付いていたら
  何もしない（拒否）。
- 安全性: 実行後も `:os-focus` は変わらない（≠ `target`）ので、破壊的操作は OS が `target` を確認するまで止まる
  （E12）。**既知のトレードオフ**: Core は「ユーザーのクリック」と「Jwno/OS の上書き」を区別できない
  （どちらも `focus-changed`）。250ms 以内に別の管理ウィンドウへユーザーが移した場合は上書きされる。
  人の反応時間（キー入力から意図的な操作まで通常 250ms を超える）と 1 回の上限、`:goto` を伴うバッチに限ること
  で許容する。A が効いている環境では、C が発火する理由はこのトレードオフ以外には、フォアグラウンドロックなど
  OS 側の失敗に限られる。**A が効いている場合の C の利得は実験で示されていない**ので、A のみで運用できるか
  実機で確かめ、不要なら `:reassert?` を既定 false にする。

### アダプタへの要件（案 A。Jwno アダプタを作るときの必須条件。**Windows 未検証**）
- **A-1** Jwno が `:virtual-desktop-changed` フックの**直後に**自分で呼ぶ `wm :set-focus`（`win.janet` の
  `wm-desktop-name-changed`。フックを同期で呼んだ直後の同じ呼び出し内）の **1 回分だけ**を抑止する。実現手段の
  一例: フックでフラグを立て、window-manager の `:set-focus` のラッパーが、フラグが立っていれば 1 回捨ててフラグを
  下ろす。スパイクでは葉の `set-focus-to-hwnd` を全部握りつぶして 10/10 だったが、**本番ではこの狭い抑止にする**。
- **A-2（必須）** それ以外の Jwno のフォーカス操作（`cmd.janet` の組み込みコマンド、ui-hint、scratch-pad）と、
  **アダプタ自身の `:focus` ポートの経路には触れない**。アダプタの `:focus` を
  `(:set-focus-to-hwnd wm ...)` で実装してはならない（A の抑止対象と共有すると Core の `:focus` が全部消える）。
  `with-activation-hooks` 経由の `:frame-activated` 等も同時に止まるので、影響を確認する（単一モニタなら害は無い想定）。
- **A-3** Jwno の版を固定し、起動時に自己診断する。ラップできなかった場合は警告をログに出して続行する
  （その場合は C 単独に退化: 実測で最終的には成功するが点滅する）。
- **A-4** 契約テスト（Windows で実行）: (a) 切替の前後で Jwno が OS フォーカスを動かさない（フックは発火する）／
  (b) 抑止中でもアダプタの `:focus` が前面を動かす／(c) Jwno の組み込みフォーカスコマンドが動く／
  (d) 実験で試していない経路 — Jwno 自身のプロセスから `:goto`→`:focus` を同期で出した場合、負荷がある状態、
  ユーザー自身による Win+Ctrl+矢印の切替、窓 3 枚以上・複数モニタ・Windows 10/11 実機。

## Consequences
- 良い: ADR 0005 §3 の規約が Linux のフェイクで検査できる。アダプタは「ポートの実装」だけになり、
  Jwno 変更の影響面積が小さい。
- 悪い: ポートの形（特に `:enumerate` の facts、`:foreground` の所有者正規化）は **想像した API**。
  実物に合うかは契約テストまで未検証。**Windows 未検証**。
- 悪い: R-4 の再観測は、`foreground` が不安定な環境で `focus-changed` の往復を増やす。silent なので
  効果は出ないが、頻度は実機で見直す。

## 暫定の決定: `:goto` 直後の競合の緩和策は A を主、C を補助（2026-10-31）

`:goto` の直後の `:focus` は、Jwno が切替後に自分で行う再フォーカスに上書きされる（切替から約 100ms 以内）。
ホスト型 Windows Server 2022 で、PowerShell（別プロセス）からの合成操作による比較実験をした
（`docs/spike/2026-10-31-hosted-windows.md`。各 n=10。**実機ではない**。10/10 の 95% 信頼区間はおよそ [69%, 100%] で、
A・B・C の間の優劣はこの標本では区別できない。区別できるのは「なし」と他の差だけ）:

| 案 | 内容 | 成功 | 着地 | 欠点 |
|---|---|---|---|---|
| なし | 切替直後に `:focus` | 0/10 | 3ms | 毎回 B に戻される |
| A | Jwno の `set-focus-to-hwnd` を握りつぶす | 10/10 | 4ms | Jwno 内部との結合。版に依存。範囲を狭める必要（A-1/A-2） |
| B | 150/250/500ms 待ってから `:focus` | 10/10 | 156/265/516ms | 待つ間 Jwno の選んだ窓が見える。遅延は負荷依存 |
| C | 即 `:focus`、250ms 後に不一致なら 1 回再発行 | 10/10 | 4ms（点滅後 ~280ms） | 毎回 C→B→C と点滅 |

**A を主、C（R-10 + Core の `:reassert-focus`）を補助とする。B は採らない**（遅延が負荷依存で、待つ間の見た目も悪い）。
「暫定」の意味: 上の実験が試していない経路（A-4 (d)）が、実機の契約テストで通るまで確定にしない。特に
(1) 実験の `SetForegroundWindow` は別プロセスから出しており、Jwno のプロセスから同期で `:goto`→`:focus` を出す本番とは
フォアグラウンドロックの条件も処理順序も違う、(2) 負荷で Jwno の再フォーカスが 250ms より後に来ると C は見逃す
（250ms の根拠は実測の 15〜30ms との比で、負荷時の保証は無い）、(3) A が効いているときの C の利得は未実証。
A が使えない場合は C 単独に退化し、C が使えない設定（`:reassert? false`）なら A 単独になる。

`:focus` を別デスクトップの窓へ出すと暗黙の `:goto` になる（実測）。Core が `:goto` を先に出す現在の順序は維持し、
「`:focus` の対象は `:current` のワークスペースの窓に限る」を E2 の拡張として不変条件に加える（INVARIANTS Q5）。

## Confirmation
- フェイクポートのテスト（RT-1〜RT-9）: RT-1 再入しない・drain 完了／RT-2 保存が先／RT-3 `:close` は
  フェイク OS のフォアグラウンドと完全一致のときだけ（owned ダイアログ回帰）／RT-4 到着順・欠落を
  ランダムにしても真のフォアグラウンド以外を close しない／RT-5 失敗を含むバッチ 1 つから連鎖する回復は 3 回まで（成功したバッチを挟まない限り再予約しない）／RT-6 ポートが投げても
  次の dispatch が処理される／RT-7 再観測は連鎖せず注入数に上限／RT-8 起動中に届いた event も入る／
  RT-10 成功した `:goto`+`:focus` のバッチの 250ms 後に `[:command :reassert-focus]` が dispatch される（`:goto` が
失敗したバッチ、`:goto` を含まないバッチ、`:reassert? false` では dispatch されない。連打は後勝ちで、古いタイマーは無害）／RT-11 `:reassert-focus`
の結果の `:focus` が実行されても再発行は連鎖しない（pending が下りている）／RT-9（`:goto` の失敗を含む）通知を遅延・重複・欠落させても、通知が止まった後に refresh と観測でモデルと OS が一致。特に「close キーとフォーカス通知を逆順に届けても誤 close
  しない」（ADR 0005 Confirmation）、effect が投げても state が保存済み、再入しない、回復が有限回で止まる。
- 実装前に Opus レビュー。アダプタは別 ADR/タスクで契約テストと共に。

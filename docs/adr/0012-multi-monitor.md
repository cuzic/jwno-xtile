# 0012. 複数モニタ: モニタごとの「見えているワークスペース」

- 状態: Accepted（改訂 3、2026-11-02。Opus レビュー 2 回で収束。実装は段階ごとに Opus がレビューする。複数モニタの実機は未検証）
- 日付: 2026-11-02

## Context

Core は単一モニタを前提にしている（`:screen` が 1 つの矩形、`:current` が見えているワークスペース 1 つ）。ADR 0006 D-4・ADR 0007 は単一モニタと書き、`adopt-existing!` は主モニタの外の窓を取り込まない（Opus M1 (e)）。
xmonad は、モニタ（Screen）ごとに「見えているワークスペース」を 1 つ持つ（`StackSet` の `current`・`visible`・`hidden`）。このプロジェクトは xmonad の StackSet に厳密に合わせる方針（ADR 0007）なので、複数モニタも xmonad のモデルに合わせる。

**事実**: Jwno の `(:enumerate-monitors wm)` は、各モニタの `:rect`、`:work-area`、`:device`、`:dpi`、`:flags`（主モニタか）を返し、`:monitor-updated` フックでモニタの変化を知らせる（`win.janet`）。DPI の違うモニタ間の移動は
`transform-hwnd` が `scale` で扱う（`win.janet:266`）。複数モニタの実機は**未検証**（手元の実機は 1 画面）。

## Decision

### D-1 状態: `:screens` と `:focused-screen`
- `:screens`: モニタごとの `{:rect 作業領域 :ws タグ}` の列（位置の順＝左上から。添字がモニタの識別子）。`:focused-screen`: フォーカスのあるモニタの添字。
- **後方互換のミラー**: `:screen`（フォーカスのあるモニタの矩形）と `:current`（そのモニタのワークスペース）は、これまでどおり State に残し、`:screens` と `:focused-screen` から**常に導かれる**（不変条件 M-1）。
  モニタが 1 つなら、状態も effect も今と同一で、既存のテストは変更なしで通る（段階 1 の合格条件）。
- 各ワークスペースは**高々 1 つのモニタ**に見える。`vis(s)` を「**全モニタの見えているワークスペースの窓**」に広げる（ADR 0006 の H-a〜H-e、D-6、D-7 の `vis` を置き換える。単一モニタでは同じ）。

### D-2 配置
- `placements` は、見えているワークスペースごとに、そのモニタの矩形で計算する（今の `arrange` を各ワークスペースに適用）。`:place` は全ての見えているワークスペースのタイルに出る。見えていないワークスペースの窓は今までどおり `:hide`（park）。
- **ワークスペースがモニタを移るとき**（入れ替え・`goto`）は、移った窓すべてに `:place`（新しい矩形）が出る。park との相互作用は変わらない（`:show` → `:place`）。

### D-3 コマンドと意味（xmonad に合わせる）
- `goto tag`（xmonad の `view`）: `tag` が**どこかのモニタに見えていれば**、そのモニタにフォーカスを移す（ワークスペースは動かない）。見えていなければ、**フォーカスのあるモニタ**に `tag` を表示する（元のワークスペースは見えなくなる）。
  モニタが 1 つなら、今の `goto` と同じ。
- `send tag`（xmonad の `shift`）: 窓を `tag` へ移す。`tag` が別のモニタに見えていれば、窓はそのモニタに現れる（見える）。
- 新しい command: `focus-screen next|prev`（xmonad の `mod-w/e/r` 相当。モニタ間のフォーカス移動）、`send-to-screen next|prev`（窓を隣のモニタの見えているワークスペースへ）。
  既定の束縛は `Alt+w`／`Alt+e`（フォーカス）、`Alt+Shift+w`／`Alt+Shift+e`（送る）。
- **意図的な差異**（ADR 0007 に追記）: 他のモニタの見えているワークスペースの窓への OS フォーカスの観測は、**そのモニタへフォーカスを移す**（xmonad の `focusWindow` と同じ。単一モニタの (a) と整合: 見えている窓へのフォーカスは切り替えではない）。

### D-4 event と観測
- 新しい観測 event `[:screens-changed [{:rect r :device d} ...]]`（モニタの列。接続・解除・解像度・DPI の変化）。**単一の `[:screen-changed rect]` は残す**（モニタ 1 つの互換。内部では `:screens` の 1 要素の更新）。
- モニタが増えたら、新しいモニタには、まだどのモニタにも見えていないワークスペースの先頭を割り当てる（xmonad と同じ）。**減ったら**、そのモニタのワークスペースは見えなくなる（`hidden` へ）。窓は失われない（park）。
- `windows-observed` の `tag` が nil（不明）の窓は、**窓の中心を含むモニタの見えているワークスペース**へ入れる（今までは現在のワークスペース）。モニタの情報は facts（`:monitor` 添字）として Shell が付ける。

### D-5 アダプタ
- `work-area`（主モニタ）を `monitors`（全モニタ）に広げ、`:screens` を `(:enumerate-monitors wm)` から作る。`:monitor-updated` で `[:screens-changed …]` を流す。
- `adopt-existing!` は、全モニタの窓を取り込む（ADR 0010 の「別モニタは取り込まない」を置き換える）。窓の facts に、中心を含むモニタの添字を付ける。
- `recover-strays` の戻し先は、窓の元のモニタ（またはそれが無ければ主モニタ）の作業領域。
- DPI の違うモニタ間の移動は `transform-hwnd` の `scale` に任せる（未検証）。

### D-6 段階
- **段階 1（Core のみ）**: D-1 の状態、`vis` の拡張、D-2 の配置。モニタ 1 つで既存の全テストが無変更で通る。モニタ 2 つのプロパティテスト（各窓は 1 つのワークスペース、各ワークスペースは高々 1 つのモニタ、配置はモニタの矩形を埋める）。
- **段階 2**: D-3 のコマンド、D-4 の event、キーマップ。xmonad の StackSet との差分テスト（`view`／`shift`／`focusScreen` を `test/xmonad-model.janet` に足す）。
- **段階 3**: アダプタ（D-5）。複数モニタの実機での検証（手元に無い。ホスト CI では 1 画面。仮想的な複数モニタは作れない）→ unverified on Windows として出す。

### 不変条件（追加）
- **M-1** `(s :screen)` は `(screens[focused]).rect`、`(s :current)` は `(screens[focused]).ws`。**M-2** `:screens` の `ws` は互いに異なり、全て `:tags` の要素。**M-3** `vis(s)` は全モニタの見えているワークスペースの窓の和集合で、
  `:hide`／`:show` はその差分から導かれる（H-a〜H-e を `vis` の定義の置き換えで保つ）。**M-4** 単一モニタのとき、全ての event・command の結果が従来と一致する（互換のプロパティテスト: 旧実装を参照モデルにした差分テストはできないので、既存のテスト全通過で担保する）。

## Consequences
- 良い点: xmonad の複数モニタの意味に合う。単一モニタの利用者には変化が無い。
- 悪い点: Core の変更が広い（`:current` を使う 24 か所、`vis` を前提にする不変条件）。複数モニタの実機が無く、DPI の違いやモニタの抜き差しの挙動は未検証。段階に分けて、段階 1 を完全な後方互換にすることでリスクを抑える。


## 改訂 2（2026-11-02。Opus レビュー M12-H1・M1〜M6・L1〜L4 を反映。D-1〜D-6 と食い違う点はここが優先）

### 「見えているか」と「フォーカスのあるモニタか」を分ける（M12-H1）
`(st/visible-tag? s tag)`（どれかのモニタに見えている）と `(st/screen-of s tag)`（そのモニタの添字）、`(st/current s)`（フォーカスのあるモニタのワークスペース）を Core の唯一の判定関数にする。`(s :current)` との比較は全て次のどちらかに書き換える。

| 規則 | 判定 |
|---|---|
| `stray-id`（`:os-focus` の窓が「見えていない」ワークスペースにある） | 見えている（どのモニタでも） |
| `window-dragged` の対象（フロートにする、ドラッグの無視） | 見えている |
| `visibility-effects`（`:hide`／`:show`） | 見えている（`vis(s)` の和集合） |
| `windows-observed` の前面の採用、`open-window` の external の解除 | 見えている（その窓のモニタへ `:focused-screen` を移す） |
| `send-focused` の宛先の可否 | 宛先が現在のワークスペースと違えばよい（別のモニタに見えているものも許す） |
| `focus-window`（OS のフォーカスの観測） | 見えている窓なら `:focused-screen` をそのモニタへ移し、external を下ろす（xmonad の `focusWindow`。ADR 0007 (a) と整合）。見えていなければ external |
| `focused`／`actionable?`、Q5（`:focus` の対象）、`reassert-focus`、`settle-pending` | フォーカスのあるモニタ |
| `stray-effect` の「空なら `[:focus-none]`」 | フォーカスのあるモニタのワークスペースが空（M12-L2。他のモニタに窓があっても sink へ。sink は 1×1 で (-32000) にあり、どのモニタとも結び付かない） |
| `:follow`、`goto` の可否、`desktop-changed` | フォーカスのあるモニタ（`goto` は D-3 の改訂のとおり） |
Core の原則（`update.janet` 冒頭）を「`:focused-screen` は観測（見えている窓へのフォーカス）か `goto`／`focus-screen` でだけ変わる」に改める。段階 1 の合格条件に、「2 モニタの state で、全ての event の後に `stray` が『見えていない窓』だけを指す」を加える。

### 状態にミラーを保存しない（M12-M1）。段階 1 を 1a・1b に分ける
`:current`／`:screen` は State から外し、`st/current`・`st/screen`（`:screens` と `:focused-screen` から導く関数）にする。書き込みは `st/set-current`（フォーカスのあるモニタの `ws` を変える。そのタグが他のモニタに見えていれば `:focused-screen` を移す）に一本化する。
- **段階 1a（純粋なリファクタ）**: `(s :current)`／`(s :screen)` の読み・書きを全て `st/current`・`st/screen`・`st/set-current` に置き換える。State の表現はまだ `:current`／`:screen` のまま（モニタ 1 つ）。**既存のテストは、直接 `(s :current)` を読む箇所だけ `st/current` に直す以外は無変更で通る**。振る舞いは変えない。
- **段階 1b**: 表現を `:screens`／`:focused-screen` に替える。

### `goto` は `greedyView` を既定にする（M12-M2）
xmonad の既定の `mod-N` は `greedyView`。`goto tag` は、`tag` が別のモニタに見えていれば**現在のモニタと入れ替える**（両方の窓に `:place`、`:hide`／`:show` は出ない）、見えていなければ現在のモニタに表示する。`view`（見えているモニタへフォーカスを移すだけ）は別のコマンド `:view tag`。
単一モニタでは `goto`＝今の `goto`。`xmonad-model.janet` の差分テストに `greedyView` と `view` の両方を入れる。

### モニタの識別と抜き差し（M12-M3）
モニタの識別子は Jwno の `:device`（デバイス名）。`[:screens-changed [{:device d :rect r} …]]` の処理: (1) 同じ `:device` のモニタには**同じ `ws` を残す**、(2) 消えたモニタの `ws` は見えなくなる（hidden。窓は park で失われない）、
(3) 新しいモニタには、見えていないワークスペースの先頭を割り当てる。`:focused-screen` は `:device` で持ち、消えたら主モニタへ。添字は表示の順序（左上から）にだけ使い、状態の識別子にしない。
xmonad の `rescreen`（X の画面の順で割り当て直す）との違いを ADR 0007 の差異の表に足す。

### 新しい窓の行き先は 1 つの規則（M12-M4）
新しい窓（`window-seen`／`window-opened`／snapshot の未知の窓）は、xmonad の `manage` と同じく**フォーカスのあるモニタのワークスペース**へ入れる（窓の中心は使わない。event の到着順に依存しない）。窓の中心でモニタを決めるのは、**起動時の最初の snapshot（`adopt-existing!`）だけ**で、
どのモニタにも含まれない窓（画面外・最小化）は主モニタへ。`:hidden-from` は中心より優先。D-4 の「窓の中心を含むモニタ」の記述を、この規則で置き換える。

### モニタをまたぐドラッグ（M12-M5）
`[:window-dragged id rect]` の rect の中心が別のモニタにあれば、窓をそのモニタの見えているワークスペースへ移す（xmonad の `float` と同じ）。フロートにするのは今のまま。

### テスト計画（M12-M6）
- **M-4 の直接のテスト**: 段階 1a の着手前の `src/core/` を `test/reference/core-v0/` に**凍結して写し**（`./` の import だけなので、そのまま読み込める）、単一モニタの state に対するランダムな event の列で、新旧の `update` の `:state`（`:screens`・`:focused-screen` を除く射影）と `:effects` が一致することを検査する。
- `test/xmonad-model.janet` を拡張する: `view`／`greedyView`／`shift`／`focusScreen`／`rescreen` を StackSet.hs から転記。プロパティテストに M-1〜M-3、「各モニタの配置はそのモニタの矩形を埋め、外に出ない」、「stray は見えていない窓だけ」、「2 モニタでの H-c のミラー」を入れる。

### その他（M12-L1〜L4）
`window-surfaced`（ADR 0006 改訂 5）は、窓が実際にあるモニタ（中心）の見えているワークスペースへ入れる（段階 2 で更新）。park の往復の後の大きさ（DPI の違うモニタ。`WM_DPICHANGED`）を契約テストの項目に入れる（unverified on Windows）。
`:screens-changed` の直後の一定時間（例: 10 秒）は、再 park の回数を数えない（Windows がモニタの変化で窓を救出するため。ADR 0006 R5-M1 と同じ扱い）。

### 採らなかった案
- **モニタごとに独立した State**（Core は単一画面のまま、モニタの数だけ持つ）: 実装は小さいが、ワークスペースがモニタに固定され、`send` で別のモニタへ送る・`goto` で別のモニタのワークスペースを呼ぶ（`greedyView`）ができない。ADR 0007 の xmonad 互換の方針に反する。
- **xmonad の StackSet の形をそのまま写す**（`:current` を Screen、`:visible` を Screen の列、`:hidden` をワークスペースの列）: 差分テストは直接になるが、`:screens`＋`:focused-screen` と等価で、既存の State（`:workspaces`）との整合は `:screens` のほうが小さい変更で済む。


## 改訂 3（2026-11-02。Opus 2 回目の確認 M12b-M1〜M3・L を反映。収束）
- **`:refresh` の 3 集合（M12b-M1）**: `hidden-ids`（`:hide` を出し直す窓）、`all-places`（`:place` を出し直す窓）、`:show` の列（可視の窓）は、判定表に加え、**全モニタの見えているワークスペース**で作る
  （2 モニタで `:refresh`（モニタの変化・R-8 の回復）のたびに、もう一方のモニタの窓が park されない）。`property-test.janet` の `vis-of`（`current-ws` の窓）も `vis(s)`（全モニタ）に直す。段階 1 の合格条件に
  「2 モニタの state で `:refresh` が、見えている窓に `:hide` を出さない」を加える。
- **フォーカスのあるモニタが消えたとき（M12b-M2）**: xmonad の `rescreen` と同じく、**現在のワークスペースは必ず残す**。消えたのが `:focused-screen` のモニタなら、そのワークスペースを残ったモニタのうち
  フォーカスを移す先（主モニタ）に表示し、そのモニタの元のワークスペースを hidden にする（窓は park。作業中の窓が隠れない）。
- **フロート（M12b-M3）**: フロートには `:place` が出ないので、`greedyView` の入れ替え・別のモニタでの `goto`（park からの復帰）で、フロートが元のモニタに残る。xmonad はフロートをモニタの矩形に対する**相対座標**で持つ。
  **段階 2 で決める**: ワークスペースが別のモニタへ移るとき、そのワークスペースのフロートを、モニタの矩形の差だけ動かす（`[:move-float id rect]` 相当の effect。Core がフロートの位置を持たない ADR 0008 の方針との整合を段階 2 の ADR 追記で扱う）。
  段階 1 では、モニタ 1 つのとき影響が無い。
- **Low（実装時のレビューで足りる）**: 段階 1b でテストの `{:current …}` の作り方が空振りしないよう、`st/make` に集約する。`core-v0` との比較の射影は `:screens`・`:focused-screen` を除き、`:current`・`:screen` は `st/current`・`st/screen` で比べる。
  `:device` の安定性（同じ物理モニタが同じ名前を保つ前提）は unverified on Windows。`greedyView` で空のワークスペースを呼んだときの `[:focus-none]` は、フォーカスのあるモニタのワークスペースが空かで決まる（差異として ADR 0007 に書く）。

# 0006. ワークスペースの実装方式とモニタモデル

- 状態: Accepted（改訂 3: 案 2 に決定。改訂 4（D-6・D-7、2026-11-01〜02）は実装済み・実機未検証。Opus レビュー 1 回の High 3・Med 5 を反映。Core の hide/show・アダプタの park・回復を実装し、ホスト型 Windows（Server 2022 と Server 2025）の契約テスト 45 項目で検証済み。実機（Windows 11、空の専用デスクトップのみ）で基本の動作を確認。Opus の実装後の再確認（2026-11-01、High 3・Med 8）の指摘に対応中）
- 日付: 2026-10-31

## Context

xmonad のワークスペースはモニタごとに表示される（Xinerama）。Windows の仮想デスクトップは
全モニタで同時に切り替わる。Jwno 自体にデスクトップの切替・移動コマンドは無い（`cmd.janet`
で確認）。公開 COM の `IVirtualDesktopManager` は他プロセスのウィンドウを移動できない、と広く報告されている
（公式ドキュメントの明記ではなく、出典は未整理）。そのため
`VirtualDesktopAccessor.dll`（非公開 COM を使い、Windows のビルドごとに壊れうる）が前提に
なる。これは ADR 0001 の「壊れる面積を小さく」と衝突する。
現在の Core は固定タグ・単一モニタを仮定している。ユーザーが OS 側でデスクトップを
追加・削除・改名すると、未知のデスクトップの `:desktop-changed` は無視され、モデルと現実が食い違う。

## Considered Options

1. **仮想デスクトップ = ワークスペース**（jwno-layout-tall 方式）。OS の機能で他ワークスペースの窓が隠れる。モニタごとの独立切替は不可。
2. **自前の hide/show**: ワークスペースは WM 内のグループ。切替では、離れるワークスペースの窓を隠し、入るワークスペースの窓を出す。OS の仮想デスクトップは使わない
   （komorebi や GlazeWM など Windows の既存のタイル WM が採る方式）。
3. 案 1 の読み取り側だけ（VD の番号 → タグ。ADR 0010 D8）を使い、切替は案 2。

## Decision

**案 2 を採る。** ワークスペースは WM 内のグループで、OS の仮想デスクトップとは独立。根拠は、ホスト型 Windows Server 2022 での実験（`spike/probe-workspaces.ps1`、2026-11-01）:

| 実験 | 結果 | 案 1 への含意 |
|---|---|---|
| P1 公開 COM `IVirtualDesktopManager::MoveWindowToDesktop` で**他プロセスの**窓を別デスクトップへ | 両方向とも `0x80070005`（E_ACCESSDENIED）。窓は動かない | `:send` は公開 API では**不可能**。非公開の `IVirtualDesktopManagerInternal`（Windows のビルドごとに壊れる）が要る |
| P2 `Win+Ctrl+矢印` の注入で切り替える際、Alt／Shift／Alt+Shift が押されたまま | **切り替わらない**（修飾キー無しなら 10ms で切り替わる） | 束縛は `Alt+<n>`。物理的に Alt が押されているので `:goto` は確実に動かない。押しているキーを一旦離す注入は、ユーザーの入力を壊す |
| P3 3 つのデスクトップを 12 回ランダムに移動（修飾キー無し） | 12/12 成功、約 360ms／ホップ | キー注入自体は動くが、P2 の問題と、デスクトップの作成・削除の管理が残る |
| P4 他プロセスの窓を隠す | `ShowWindow(SW_HIDE)` は効き、`SW_SHOW` で戻る。cloak（`DWMWA_CLOAK`）は `E_ACCESSDENIED`。画面外（-32000）への移動も効く | 案 2 は、公開 API だけで、他プロセスの窓を隠せる |

案 1 は公開 API だけでは `:send` が実現できず、`:goto` も修飾キー下で動かない。非公開 API（`VirtualDesktopAccessor.dll` など）に頼ると、ADR 0001 の「Jwno の壊れる面積を小さく」と衝突する。

### 隠し方: 既定は `:park`（画面外へ移動）。`SW_HIDE` は opt-in（実装しない）
Opus レビュー（H1・H3）に従い、**既定を `:park`（窓を画面外 -32000 へ移して可視のまま置く）にする**。理由:
- `SW_HIDE` した窓は、タスクバーにも Alt-Tab にも出ない。WM が落ちる・状態を捨てる・デスクトップが削除されると、プロセスは生きているのにユーザーが操作できない窓
  （未保存のエディタ）が**永久に失われる**。`:park` の窓はタスクバーに残り、クラッシュしても失われない。
- Jwno は不可視の窓を木から外し（`clean-up-hwnds`、`wm-hwnd-alive?`）、`:window-removed` を出す。`:park` の窓は可視のままなので木に残り、`enumerate` に出て、`:place` が
  窓を見つけられる。`SW_HIDE` だと、再表示後の `:place` が「窓が無い」で投げ、R-8 の snapshot が Core から窓を消す連鎖になる。
- `:sw-hide`（タスクバー・Alt-Tab から消せる）は将来の opt-in とし、採るなら、終了時の全復元・隠した hwnd の永続化と起動時の回復・`window-removed` の抑止・再表示の確認を必須にする。**今回は実装しない。**
- `:park` の欠点: タスクバー／Alt-Tab に残り、そこから選ぶと画面外の窓にフォーカスが移る。ADR 0007 (a)・ADR 0005 R1 のまま（ワークスペースは切り替えない。external になる）。
  将来「他のワークスペースの窓へのフォーカスで、そのワークスペースへ goto する」オプションを検討する。

### D-1 Core: hide/show を effect として導出する
- ワークスペース（タグ）は WM 内のグループ。Core は OS の仮想デスクトップを知らない。`:goto`／`:send` の判断は今のまま Core にある。
- 新しい effect **`[:hide id]`**（可視でなくなる）と **`[:show id]`**（可視になる）を、`derive-effects` が新旧の state の差分から導出する（ADR 0001 の語彙に追加）。
  `vis(s)` を可視ワークスペースの窓の集合、`all(s)` を全ワークスペースの窓の集合として、
  - `hide = { id ∈ all(new) : id ∉ vis(new) ∧ (id ∈ vis(old) ∨ id ∉ all(old)) }` — 可視のワークスペースから別のワークスペースへ移った窓、または可視でないワークスペースに**新しく**
    現れた窓（実際には画面にある）。**`all(new)` にある窓だけ**なので、閉じた窓・ユーザーが最小化した窓・幽霊（`drop-hidden`／`window-closed`／`windows-observed` の削除）には出ない（レビュー H2）。
  - `show = { id ∈ vis(new) : id ∉ vis(old) ∧ id ∈ all(old) }` — 別のワークスペースから可視になった窓。新規の窓や snapshot で追加された窓は、すでに画面にあるので出ない。
  順序は **`hide` → `show` → `place` → `focus`**。`explicit`（`[:goto]`／`[:send]`）が先頭。
- `[:goto tag]` と `[:send id tag]` は語彙に残す（ログ・将来のモニタ対応）が、アダプタは何もしない（hide/show が実体）。
- 不変条件: **H-a** `:hide` の対象は新しい state で可視でないワークスペースにある窓に限る／**H-b** `:show` の対象は旧の state で可視でないワークスペースにあった窓に限る／
  **H-c（ミラー）** effect の `hide`/`show` と、可視ワークスペースに直接現れる窓だけを適用した「画面にある窓の集合」は、常に `vis(s)` と一致する（E7 の hide/show 版）／
  **H-d** `:show` されるフロートに `:place` は出ない。`:send` で出ていった窓に `:place` は出ない／`:hide`／`:show` の対象は重複しない。

### D-2 観測: `:park` では特別な規則は要らない
`:park` の窓は可視（`visible? true`）で `enumerate` に出るので、ADR 0008 の `hidden?` 規則は変わらない。可視でないワークスペースの窓には `placements` が無いので、`window-moved` は無視される
（アダプタが自分で止める。D-3）。`:sw-hide` を採る場合に限り、「可視でないワークスペースの hidden な既知の窓は残す」規則（ADR 0008 の改訂）が要る（将来）。

### D-3 アダプタ: park の実装（ADR 0010 に追記）
- `:hide id` → 窓の現在の見える枠を **`parked[id]` に記憶**してから、同じ大きさで (-32000, -32000) へ `transform` する。`:show id` → 記憶した枠へ戻す（タイルはこの後の `:place` が上書きする。
  フロートは元の位置に戻る）。`:place`・`:focus` は、対象が `parked` にあれば先に戻す（防御）。`parked` は OS 境界の記憶（Core の状態ではない）。
- **自分で park した窓は park したままにする**: ポーリングの比較で、`parked` の窓の実際の位置が park した位置と違えば（アプリが自分で動かした）、park し直す。Core には流さない
  （可視でないワークスペースの窓は `placements` が無く、Core は無視する）。
- **回復（H1）**: `:shutting-down` フックで、`parked` の窓を全部元の枠へ戻す。起動時（`install`）に、Jwno の木にある窓で位置が (-30000 以下) のものを、`parked` に無くても作業領域へ戻す
  （前回クラッシュしたときに画面外に残された窓の回復）。
- `:goto`／`:send` のポートは何もしない。`:window-removed` の抑止は要らない（park の窓は木に残る）。
- `:place` と `:focus` は、レビュー H3 の方針に沿って、窓を Jwno の木から引けないときに投げる現行の挙動のまま（park の窓は木にあるので問題にならない）。

### D-4 OS の仮想デスクトップとの関係（ADR 0010 D8 を改める）
- ワークスペースと OS の仮想デスクトップは独立。**段階 1: Core は現在の仮想デスクトップの窓だけを扱う。** OS のデスクトップ切替では Core の state を持ち越さず、`windows-observed` で
  新しいデスクトップの窓に同期する（前のデスクトップの窓の順序・フロート・ワークスペースの割り当ては失われる）。ワークスペース機能を使うなら **OS の仮想デスクトップは 1 つで使う**ことを
  勧める（2 つ以上あれば起動時に警告）。デスクトップごとに Core の state を入れ替える設計は、キューにある古い event との競合・`focus-changed` と `virtual-desktop-changed` の
  順序・削除されたデスクトップの state の扱いが複雑で、利得に見合わないため見送り（需要が出たら ADR を起こす。レビュー M3）。
- ADR 0010 D8 の「VD 番号 → タグ」「予約タグ `"0"`」「起動時の `desktop-changed`」（ADR 0009 R-7）は**廃止**する。イベントのタグは常に nil（Core が持つワークスペースにそのまま入る）。
  `:enumerate` と `window-created` は、現在のデスクトップの窓だけを対象にする（Jwno の `last-vd` と窓のデスクトップの guid を比べる。`last-vd` が無い＝デスクトップを作っていない環境は全窓が対象）。
  `:virtual-desktop-changed` では `[:windows-observed (enumerate)]` を流して同期する。A（OS のデスクトップ切替後の Jwno の再フォーカスの抑止）は、ユーザーが OS のデスクトップを切り替えたときのために残す。
- `Alt+<n>` は `[:command :goto n]` にそのままなる。キー注入は無く、修飾キーの問題も無い。R-10（`:goto` 後の `:reassert-focus`）は、案 2 の `:goto` では OS のデスクトップ切替が起きず
  Jwno の再フォーカスとの競合が無いので不要になる。`:pending-focus` は害が無いので残し、アダプタの `:reassert?` の既定は false にする（案 1 の名残）。

### D-5 既知の制限と、検討して採らなかった案
- 案 1 の `:goto` だけなら、キー注入を使わず、WM が OS デスクトップごとに持つ補助窓へ `SetForegroundWindow` する（OS が暗黙にそのデスクトップへ切り替える。実測済み）方法がある。ただし `:send` は
  公開 API では不可能（P1）なので、案 1 は救えない。
- Jwno の frame／viewport で窓を画面外へ「スクロール」させる方式は、`:park` の変種で Jwno への結合が強いので採らない。
- 窓が画面外にある間もアプリは動き続け、通知も出る。アプリが自分で位置を戻す場合は、ポーリングの比較で park し直す（D-3）。`SW_HIDE` のように owned 窓が残る問題は `:park` では起きにくい
  （owned 窓は所有者とは独立に動くので、**owned な tool window は画面外に移らない**可能性がある。契約テストで確かめる）。
- **ワークスペースに属さない窓は、`goto` しても画面に残る**（Opus M5。unverified on Windows）: 全画面の窓（ADR 0008 の `hidden?` で Core から外れる）と、`ignore` した窓。
  どちらも Core の `all` に無いので `hide` の対象にならず、他のワークスペースのタイルを覆いうる。ユーザールールで `ignore` した窓は「全ワークスペースに常駐する」窓として意図どおり。
  全画面の窓は、最小化と同じく `:hidden-from` で元のワークスペースを覚える（M4）が、画面からは隠さない。必要になったら、全画面を抜けるまで park する案を検討する。
- モニタは単一（下の「モニタモデル」は変えない）。

## スパイク記録（2026-10-31、ホスト型 Windows Server 2022。実機ではない）
詳細は `docs/spike/2026-10-31-hosted-windows.md`。
- 公開 COM `IVirtualDesktopManager` の `GetWindowDesktopId` / `IsWindowOnCurrentVirtualDesktop` は動いた。
- `Win+Ctrl+D` で仮想デスクトップを作成・切替でき、Jwno は `get-all-desktops` で 2 件を列挙した
  （レジストリ `VirtualDesktops` を読む実装）。窓には `desktop-info {:id :name}` が付く。
- **未確認**: 他プロセスのウィンドウを動かせるか（`MoveWindowToDesktop`）、`VirtualDesktopAccessor.dll` の
  動作、Windows 10/11 でのビルド依存。案 1 か 2 かの決定にはまだ足りない。

## ADR 0010 との関係（2026-11-01）
案 2 が選ばれたので、ADR 0010 D8（VD 番号 → タグ）は廃止し、D-4 の「現在のデスクトップの窓だけ」に置き換える。

## 実装後の記録（2026-11-01）
- Core（`derive-effects` の `[:hide]`／`[:show]`、不変条件 H-a〜H-e とミラーテスト）、アダプタ（park・回復・現在のデスクトップのみ）、ランタイム（`:hide`／`:show` の実行）を実装した。
  ホスト型 Windows の契約テストで `goto`／`send`／終了時の復元／異常終了からの回復／仮想デスクトップの往復が通った（`docs/spike/2026-10-31-hosted-windows.md`）。
- 契約テストが、D-4 の「現在のデスクトップの窓だけ」の判定に Jwno の `last-vd` を使うと起動直後に全窓が除外される、と見つけた。窓ごとに `IsWindowOnCurrentVirtualDesktop` を使う
  （Windows 自身に聞く。同期でリトライ無し）方式に改めた。
- `:sw-hide`（opt-in）は未実装のまま。デスクトップごとの state の入れ替えは需要が出るまで見送り。
- **実機の記録（2026-11-01、Windows 11。空の専用デスクトップだけで試した）**: 新しく作ったデスクトップで、park・復帰・終了時の復元・異常終了からの回復（Notepad）が通った（`docs/spike/2026-11-01-real-machine.md`）。
  **未検証**: 以前からある窓のあるデスクトップへの切替、デスクトップの削除、park した窓を持ったままの仮想デスクトップ往復、Chromium／UWP の窓、副モニタ、全画面。新しい仮想デスクトップへの切替で Jwno の `desktop-name-changed` が届かないことがあり、その間の追従はポーリング（2 秒）任せで、追従前に focus を出すと元のデスクトップへ引き戻される恐れがある（Opus M2、未対応）。

## 改訂 4（2026-11-01。Opus の実装後レビュー H2・H3 への対応。**Proposed**: レビューと実装の後に Accepted へ）

### D-6 `:show` は「可視に新しく入った窓すべて」に出す（H2。D-1 の `show` の定義と H-b を改める）
- 問題: park 方式では「新規の窓や snapshot で追加された窓は、すでに画面にある」が偽になりうる。Core から忘れられた窓（仮想デスクトップの往復、park 中の窓を最小化して戻す、
  `enumerate` が一度飛ばした）は (-32000) に残ったまま、再び Core に現れる。このとき `:show` が出ないので、タイルは `:place` で戻るが、**フロートは画面外に取り残される**。
- 決定: `show = { id ∈ vis(new) : id ∉ vis(old) }`。`id ∈ all(old)` の条件を外す。新規の窓も `:show` を受ける。
  アダプタの `:show` は `parked` に無い窓には何もしないので、本当に新しい窓には無害（ログのみ）。
- 不変条件 **H-b（改）**: `[:show id]` の対象は、新しい `vis` にあり、旧の `vis` に無かった窓すべて。**H-c（ミラー）**: 「画面にある窓の集合」は、`:hide`／`:show` だけで `vis(s)` に一致する
  （可視ワークスペースへ直接現れた窓を「すでに画面にある」と仮定する項は不要になる。ミラーの仮定が減るので、H2 の食い違いを検出できる）。
- 影響: 新しい窓が開くたびに `[:show id]` が 1 つ増える（`:place` の前、`:hide` の後）。`runtime` の effect の実行順は変えない。`effect-rank` は変更なし。
- 検討して採らなかった案: アダプタが `windows-observed` の後に `parked` と Core の state を突き合わせて unpark する案。アダプタが Core の state を読むので、ADR 0001（判断は Core）と合わない。

### D-7 OS のフォーカスが park した窓にあるのを正す（H3。Opus の再レビュー D7-H1・H2・M1〜M3 を受けて**書き直した**。新しい effect `[:focus-none]`）
- 問題: park した窓は画面外なのに、OS のフォーカス（前面）がそこに残りうる。打鍵は見えない窓に入る（ターミナルならコマンドが実行される）。起きる場面は 3 つ以上ある。
  (a) 空のワークスペースへ `goto`／最後の窓の `send`（前面の窓が park される）。(b) 窓を閉じた後、Windows が Z 順で次の窓＝park 済みの窓をアクティブにする
  （ワークスペースが空でなくても起きる）。(c) タスクバー／Alt-Tab で park した窓を選ぶ。(a) の初案（遷移で発火）は (b) をほぼ拾えず、全画面にした窓からフォーカスを奪う穴もあった。
- 決定: 発火条件を遷移ではなく**状態**で書く。Core の関数 `stray-focus`（純粋）: 「`:os-focus` が、Core が知っている窓で、かつ可視ワークスペースに無い」ならば、
  `vis(s)` が空 → `[:focus-none]`、空でない → `[:focus (st/focused s)]`。`:os-focus` が無い／Core が知らない窓（スタートメニュー、ダイアログ、`ignore` した窓、
  全画面で `drop-hidden` された窓）なら**何も出さない**（E11 の「管理外の窓からフォーカスを奪わない」を保つ。全画面の動画からフォーカスを奪う穴も消える）。`external` は無視する
  （park した窓へのフォーカスは「ユーザーが選んだ管理外の窓」ではない）。
- 使う場所:
  1. `derive-effects`: **silent でない**遷移の結果に `stray-focus` を足す（`goto`、`send`、`window-closed`、`window-seen` など。既存の `[:focus …]` と重なるときは既存を優先し、重複して出さない）。
  2. 新しい内部コマンド **`:reclaim-focus`**（`:reassert-focus` と同じく束縛不可、K3）。実行すると `stray-focus` だけを評価する（`:refresh` からの呼び出しも同じ）。
  3. ランタイムが `:reclaim-focus` を予約する（R-10 と同じ形、250ms 後）: (i) 毎回の `focus-changed` の処理の後（これは silent なので 1. では拾えない）、(ii) `:hide`／`:show` を含む effect の実行の後。
     発火時の state で評価するので、`focus-changed P` と `window-closed A` の到着順に依存しない（D7-H1）。ポーリング（`windows-observed`、silent）で閉じたことに気付く場合も、(ii) でなく (i) の予約が後から効く。
  4. 無限ループの防止: `:reclaim-focus` が出した `:focus`／`:focus-none` が拒否される（前面ロック）と、再観測で `focus-changed` が来て再び予約される。連続 3 回で諦める
     （カウンタは `:os-focus` が可視ワークスペースの窓、または管理外になったらリセット。`:misfit` と同じ考え方）。
- 既定の挙動の決定: ユーザーがタスクバー／Alt-Tab で park した窓を選んでも、約 250ms 後に可視の窓へ戻される（見えない窓へのフォーカスは使い道が無い）。
  「選んだワークスペースへ移る」は将来の `goto` オプション（上記 D-5）で、既定にはしない。
- 空のワークスペースから空のワークスペースへの `goto` でも、管理外の窓にフォーカスがあれば何もしない（上の規則）。`goto` は空でないワークスペースへの移動では管理外の窓からも
  フォーカスを奪う（`explicit-focus`、既存の仕様）が、空への `goto` は奪わない。この非対称は意図したもの（奪う対象が無い）。
- 不変条件:
  - **F12a（活性）**: `stray-focus` の前提（`:os-focus` が既知で可視でない）が成り立つ非 silent な遷移と `:reclaim-focus` の結果には、`[:focus id]` か `[:focus-none]` のちょうど一方が含まれる。
  - **F12b（奪わない）**: `:os-focus` が無い、または Core が知らない窓なら、`stray-focus` は何も出さない。
  - **F12c**: silent な event（`focus-changed`、`windows-observed`、`desktop-changed`）の直接の結果に `[:focus-none]` は含まれない（E3 の拡張。回復は `:reclaim-focus` が担う）。
  - **F12d**: `[:focus-none]` と `[:focus id]` は同じ effect 列に同時に出ない。`[:focus-none]` は `vis(new)` が空のときだけ。状態が変わらず `:os-focus` が正しいときは何も出ない（冪等）。
  - 順序は `hide` → `show` → `place` → `focus`／`focus-none`（最後）。
- ランタイム: `execute` に `:focus-none` を足す。`run-effects` は `:focus-none` でも `observed-needed` を立てる（前面を再観測し `schedule-reobserve`）。`goto+focus?`（R-10 の予約）には含めない。
- アダプタ: ポート `:focus-none` は Jwno の `(:set-focus-to-desktop wm)`（win.janet:3669）。`wm :set-focus` を通らないので A の抑止の対象外（`desktop-name-changed` の中で動くことはない。dispatch は spawn で後回し）。
  Jwno の「現在のフレーム」は変わらない（Jwno の組み込みコマンドが park した窓を前面に出しうる。許容、unverified on Windows）。結果の `focus-changed` はデスクトップの hwnd か nil。どちらでも Core は管理外として扱い、
  `stray-focus` は出さない（F12b）ので、ループしない。**unverified on Windows**: デスクトップへのフォーカスが前面ロックで拒否されうる。そのときは 3. の再試行（3 回）で諦め、現状と同じ状態に戻る。
- 検討して採らなかった案: 空のワークスペースの代わりに「ダミーの透明窓」を持つ案。park した窓に `WS_EX_NOACTIVATE` を足す案（Jwno の transform の外で窓のスタイルを書き換える）。
  遷移ごとに発火条件を列挙する初案（上記のとおり (b) と silent の経路を拾えない）。

### D-6 の補足（Opus の再レビュー D6-M1・M2・L1・L2）
- アダプタの `:show` は「`parked` にあれば元の rect へ。無くても、窓の見える枠が x < -30000（最小化でない）なら作業領域へ戻す」（`recover-strays` と同じ判定）。`parked` が先に消える経路
  （トレイ型アプリの `SW_HIDE` を Jwno が purge した、など）でも、画面外に残らない。
- `:window-removed` フックは、`IsWindow` が真なら `parked` のエントリを消さない（死んだ窓だけ消す）。HWND の再利用で古い rect へ新しい窓を動かさないよう、
  エントリは `IsWindow` が偽になった時点（ポーリング）で捨てる。
- `:refresh` は可視ワークスペースの全窓に `:show` を出し直す（アダプタは画面外のものだけ動かす）。取り残された窓の回復手段になる。
- H-c は D-6 により Core 内では定義の言い換えになる。意味のある検査は**アダプタ側の不変条件 P-1**: 「Core の `vis(s)` の窓は画面上にある（`parked` に無い）。可視でないワークスペースの窓は park されているか最小化されている」。
  フェイクの OS（窓の位置・最小化・可視・Z 順・前面）を使ったアダプタのプロパティテストで、ランダムな操作（goto、send、close、最小化／復元、アプリ自身の `SW_HIDE`／`SW_SHOW`、
  仮想デスクトップの往復、ポーリング、`focus-changed` と `window-closed` の順序の入れ替え）の各ステップで P-1 と「前面の窓が park されていない」を検査する。閉じたときのフォーカスの受け渡しは
  「Z 順の次の可視窓」でモデル化する（unverified on Windows の仮定）。

### 実装の順序
1. 本節のレビュー（Opus、2 回目）。2. Core: `visibility-effects` の `shows`、`stray-focus`、`:reclaim-focus`、`effect-rank`、不変条件の更新（`docs/INVARIANTS.md` の H-b・H-c・F12a〜d・P-1）、
`test/update-test.janet`・`test/property-test.janet`（F12 を生成器に加える。`window-seen` で hidden を流す場合も）。3. ランタイム: `:focus-none` の実行、`:reclaim-focus` の予約（3 回で諦める）。
4. アダプタ: `:focus-none` ポート、`:show` の画面外判定、`window-removed` と `parked`、フェイク OS のプロパティテスト。5. 契約テスト（Windows。すべて unverified on Windows として結果を記録する）。

### 改訂 4c（2026-11-01。Opus の 2 回目の再レビュー R4b-H1・H2・M1〜M6・L1〜L4 を反映。D-7 のうち、ここに書いたものは上の記述を**上書き**する）
- **D-7a 発火は遅延 0、`goto` は `:os-focus` を保つ（R4b-H1）**: `goto-tag` は `:os-focus` を消さない（OS の前面は `:goto` の後も実際に旧ウィンドウのままで、これは観測の事実。ADR 0005）。
  `actionable?` は「Core のフォーカス＝`:os-focus`」を要求するので、旧ウィンドウを残しても破壊的操作は動かない（`desktop-changed` の採用ロジックへの影響は R1 系のテストで確認する）。
  これにより、空への `goto` の effect 列自体に `[:focus-none]` が含まれ、F12a で直接検査できる。`:reclaim-focus` の予約 (i)(ii) は 250ms ではなく**遅延 0**（キューの末尾）。
  OS が Z 順で次の窓を決めるのを待つ分は、既存の `schedule-reobserve`（200ms）が生む `focus-changed` からの (i) が担う（発火時の state で評価するので、待つ理由は無い）。
- **D-7b `focus-none` の行き先は、入力を飲み込む WM 自身の窓（R4b-H2。前の「ダミーの窓は利点が少ない」を撤回）**: Jwno の `set-focus-to-desktop` はデスクトップのアイコンのリストビューにフォーカスし、
  Enter で開く・Delete でごみ箱へ・F2 で名前の変更になる（推論。unverified on Windows）。H3 の害を別の害に置き換えるだけなので採らない。
  `win32.janet` に **sink 窓**を足す: 1×1、`WS_POPUP`、`WS_EX_TOOLWINDOW`（タスクバー・Alt-Tab に出ない）、(-32000,-32000) に置き、`WM_KEYDOWN`／`WM_CHAR` などを `DefWindowProc` に渡さず捨てる。
  jw32 は `RegisterClassEx`／`CreateWindowEx` を持つ（Jwno の `indicator.janet` が使っている）。ポート `:focus-none` は sink 窓を前面にする。sink 窓の hwnd は `adopt-existing!`・`recover-strays`・
  `enumerate` の対象から除く（自分の窓。クラス名で判定）。作れなかった／前面にできなかった場合は、**何もしない**（デスクトップへのフォールバックはしない。破壊的な経路を作らないため）。
  実装の前にスパイクで、ホスト型 Windows と実機の両方で「sink 窓が前面になる」「打鍵が捨てられる」を確かめる。
- **D-7c 内部コマンドと状態（R4b-M1・M2）**: `:reclaim-focus` は `:reassert-focus` と同じく束縛不可（K3）で、`:pending-focus` を下ろさない（Q3 の例外を `#{:reassert-focus :reclaim-focus}` に）。
  コマンド前の事前観測（`process-one`）は走ってよい（最新の前面で判定できる）。事前観測は `process-one` を通らないので (i) の予約を生まず、ループの防止になる。
  予約は `:reobserve-pending` と同じ「予約中フラグ」で 1 本にまとめる。連続試行のカウンタは**判断なので Core の state**（`:reclaim-tries`）。増えるのは `:reclaim-focus` が effect を出したときだけ。
  リセットは `:os-focus` が可視ワークスペースの窓、または管理外・nil になったとき。窓が消えたらそのキーは持たない（F1 系）。3 回で諦めたら `[:notify :reclaim-gave-up id]`（ログの warn）を出す。
- **D-7d 既存の不変条件の改訂（R4b-M3・L1）**: `docs/INVARIANTS.md` を次のとおり変える。**E11**: 外部（external）中の `:focus` は、ユーザーが求めたものか、`stray-focus`（`:os-focus` が可視でないワークスペースの既知の窓）に限る。
  **E6（冪等）**: `derive-effects` が `stray-focus` を足すのは**state が変わった遷移**に限る。同じ event を 2 回送った 2 回目には足さない（回復は `:reclaim-focus` が担う）。**E8・E10**: `stray-focus` の `:focus` は
  external を下ろさない（下ろすのは観測だけ）。`:refresh` は `stray-focus` を評価しない（E8 のまま）。**Q3**: 上記。**Q5**: `stray-focus` の `:focus` の対象は `(st/focused s)` なので満たす。
  `stray-focus` を足すのは「`derive-effects` が `:focus` を出さなかったとき」だけ（同じ対象なら `order-effects` の `distinct` で 1 つになる。`vis` が空のときは `:focus` が出ないので `[:focus-none]` と重ならない）。
  **F12e（収束）**: フェイク OS で `:reclaim-focus` が拒否されないなら、高々 1 回の後に `:os-focus` は可視の窓か管理外になる。および `:reclaim-focus` が effect を出すのは連続 3 回まで。
- **D-7e UX（R4b-M5）**: 既定は `:return`（250ms ではなく即座に可視の窓へ戻す）。通知のクリックやタスクバーで park した窓が選ばれた場合に、ユーザーがその窓へ行けないので、設定 `:stray-focus` に
  `:follow`（その窓のワークスペースへ `goto` する）を用意する。`stray-focus` の分岐の一つとして Core に置く（小さい）。`:return` で戻したときは `[:notify :stray-returned id]`（ログ info。ビープは既定オフ）。
  Alt-Tab／Task View の最中は前面がスイッチャー（管理外）なので何も出ない。確定後の `focus-changed` で改めて評価される（R4b-L3）。
- **D-7f 前面ロックと P-1 の破れ（R4b-M4・M6）**: タイマー起点の `SetForegroundWindow` は前面ロックで拒否されうる（特に (c) タスクバー）。3 回で諦める設計はそのまま。契約テストで、`AttachThreadInput` を使わずに
  park した窓を前面にして、`:reclaim-focus` が効くかを測る（ハーネスの前面操作とアダプタの前面操作を区別して記録）。アダプタは `:focus`／`:focus-none` を実行する前に「前面の窓が実際に画面外か」を確かめ、
  画面上なら何もしない（ログ）。これで、park に失敗して画面上に残った窓（P-1 の破れ）をユーザーがクリックしたときに、フォーカスを奪わない。`[:window-surfaced id]`（再 park できない窓を可視へ移す）は別の項目として残す。
- **D-7g その他**: 最小化の途中（ポーリングまでの最大 2 秒）に既知のまま `[:focus F]` が出ることは許容（害が小さい。R4b-L2）。`focus-none` の後の `focus-changed` は sink 窓の hwnd（未知の id＝管理外）で、
  F12b により何も出ない。契約テストで `:os-focus` の値を記録する（R4b-L4）。P-1 は「タイマーと `:reclaim-focus` を流し切った後」の性質で、前面ロックで拒否されたとき（3 回で諦める）は正当に破れる。
  フェイク OS のテストは、そのモデル（拒否するか）を入力に含める。

### 改訂 4d（2026-11-01。Opus の 3 回目の再確認 R4c-H1・H2・M1〜M4・L1〜L4 を反映。4c と食い違う点はここが優先）
- **sink 窓は Jwno の UI スレッドで作る（R4c-H1。4c D-7b の「`win32.janet` に足す」を改める）**: Jwno の main スレッドはメッセージを回さない（アダプタの `pump` はムーブフックがあるときだけ動く）ので、そこで作った窓は
  他のプロセスからの同期メッセージ（IME、`WM_GETOBJECT`、ブロードキャスト）に答えず「応答なし」になりうる。Jwno の `indicator.janet` と同じく、`(:add-custom-message ui-man …)` で UI スレッドに作成を頼み、
  前面化も UI スレッドへ依頼する。WndProc は UI スレッドで動く。スパイクの確認項目に「ムーブフック無しでも sink が応答する」を足す。
- **`:follow` は自分の副作用には反応しない（R4c-H2）**: Core の state に、`goto-tag`／`send-focused` が立て、次の `focus-changed`（観測）で下ろす印 `:stray-own` を置く。印が立っている間の `stray-focus` は、
  設定が `:follow` でも `:return` と同じ（`goto` を出さない）。F12 に「`:follow` は、自分の `goto`／`send` で前面に残った窓に `goto` を出さない」を加え、`goto` → `:reclaim-focus` の順で検査する。
- **実行前の「前面が実際に画面外か」の確認は `:reclaim-focus` 由来の effect だけ（R4c-M1）**: `:reclaim-focus` が出す effect には印を付ける（`[:focus f :reclaim]`、`[:focus-none :reclaim]`）。アダプタは印のある effect でだけ確認し、
  画面上なら何もしない（ログ）。`focus-next` や `goto` の `[:focus f]`、遷移で足す `stray-focus`（ユーザー操作の直後）では確認しない（CT-10 を壊さない）。印は `order-effects` の `distinct` で通常の `[:focus f]` と別物として扱う。
- **カウンタは id ごと（R4c-M2）**: `:reclaim-tries` は `{:id P :n k}`（struct）。`:os-focus` の id が変われば 0 から。上限（3 回）は `:reclaim-focus` にだけ掛け、`derive-effects` が遷移で足す `stray-focus` は常に評価する
  （前面ロックで 3 回失敗した後の `goto` 空でも `[:focus-none]` は出る）。リセット: `:os-focus` が可視の窓または管理外・nil になったとき、および `:reassert-focus`／`:reclaim-focus` 以外の任意の `:command`
  （新しい意図。`:pending-focus` と同じ扱い）。F1: その id が `close-window` で消えたら `:reclaim-tries` も消す（`:misfit` の処理と同じ箇所）。
- **sink の除外は hwnd で（R4c-M3）**: jw32 に `GetClassName` が無い（CT-1）ので、アダプタが sink の hwnd（`hwnd->number`）を持ち、`adopt-existing!`・`recover-strays`・`enumerate` の 3 か所で除く。
  Jwno のフィルタは `WS_EX_TOOLWINDOW` を落とすので、Jwno の木には入らない（`enumerate` は自然に除外される。明記）。
- **sink の仕様（R4c-M4・L2）**: キー入力（`WM_KEYDOWN`／`WM_CHAR`／`WM_SYSKEYDOWN`）は捨てる。`WM_CLOSE`／`SC_CLOSE` も捨てる（`Alt+F4` で閉じない）。`WM_DESTROY` されたら作り直す。
  タイトルは「xtile: 空のワークスペース」（スクリーンリーダー用）。抜け出す手段: Jwno の束縛（Jwno の低レベルキーボードフックは UI スレッドにあり、前面の窓より先に処理される。unverified on Windows）、
  マウスのクリック、`Alt+Tab`／`Win` キー。sink の前面化が拒否されたら**成功扱い**（`[:notify :focus-none-refused]` を出し、`:reclaim-tries` に任せる。R-8 の回復は走らせない）。
- **L1**: `observe-front` が生む `focus-changed` からは `:reclaim-focus` を予約しない（自分の `:focus` の観測が追いつく前に評価して試行を空費しない）。予約は `schedule-reobserve`（200ms 後）の観測、
  および外から来た `focus-changed`（Jwno のフック経由）からだけ。**L3**: `[:notify :stray-returned id]` は同じ id につき、状態が変わるまで 1 回だけ。
- **スパイクの確認項目（R4c-L4。すべて unverified on Windows として結果を記録する）**: sink が前面になる／打鍵が捨てられる／ムーブフック無しでも応答する／日本語 IME が有効でも変換ウィンドウが出ない／
  `Alt+F4` で閉じない／Narrator の読み上げ／Jwno の束縛が sink の前面で効く／sink が前面のとき `focus-changed` に何が届くか（hwnd か nil か）。

### 改訂 4e（2026-11-01。Opus の 4 回目の確認 R4d。既定の `:return` の経路は収束と判定。以下で opt-in の `:follow` と実装上の注意を直す）
- **`:stray-own` は id を持つ（R4d-M1）**: 印は `{:id A}` とし、**A 以外の `focus-changed`**、または任意の `:command` でだけ下ろす（A 自身の観測では下ろさない）。sink の前面化が拒否・遅延して
  A が前面のままでも、再観測からの `:reclaim-focus` が `:follow` で `goto` を出さず、自分の `goto 3` を打ち消さない。
- **UI スレッドの handler は複製される**ので、sink の hwnd と前面化の結果は `:send-message` の戻り値で受け取る（`:post-message` では拒否が分からない）。ランタイムの `execute` とテストは、
  印付き effect（`[:focus f :reclaim]`、`[:focus-none :reclaim]`）の形に合わせる。
- 予約 (ii)（`:hide`／`:show` を含む effect の実行後の `:reclaim-focus`）は、4c で `goto` が `:os-focus` を保ち遷移の時点で `stray-focus` が出るので**冗長**。削る（試行の空費を避ける）。予約は (i) だけ。
- スパイクで、Jwno のキーボードフックが低レベルフック（`WH_KEYBOARD_LL`）かを確かめる（sink が前面でも束縛が効く前提）。
- 状態: 改訂 4（D-6 の補足、D-7、4c〜4e）は**設計としては収束**。sink 窓に関する前提（前面化・打鍵の破棄・応答・IME・束縛）は実装前のスパイクの結果次第で、すべて unverified on Windows。
  Core 側（`stray-focus`、`:reclaim-focus`、`:stray-own`、`:reclaim-tries`）はスパイクに依存しないので先に実装できる。

### 実装の状況（2026-11-02）
- Core（`stray-focus`、`:reclaim-focus`、`:stray-own`、`:reclaim-tries`、`:show` の拡張、`goto` が `:os-focus` を保つ）、ランタイム（`:focus-none` の実行、`:reclaim-focus` の予約）、アダプタ（`:show` の画面外回復、
  `window-removed` と `parked`、印付き `:focus` の画面外確認、最小化中の窓の「後で park」、最大化の記憶）を実装した。プロパティテスト（F12a〜d、アダプタ側 P-1）で検査している。
- **sink 窓**: ホスト型 Windows Server 2022 のスパイクで、UI スレッド上で作れる・別プロセスのメッセージに答える・打鍵と Alt+F4 を捨てる・前面でも Jwno の束縛が効く、を確認した。
  前面化は、`SetForegroundWindow` を UI スレッドから呼ぶだけでは拒否され、**直前の Alt の打鍵（`SendInput`）のあと**に通った。UIA の `SetFocus` では前面にならなかった。実装は `win32.janet` の `make-focus-sink`。
  **実機（Windows 11）では 2026-11-02 の契約テストで、空のワークスペースへの `goto` で前面が sink になり、`goto` で窓が戻ることを確認した**（CT-23）。IME、Narrator は**未検証**。拒否されたときは「成功扱い＋ログ」で、`:reclaim-focus` の再試行（3 回）に任せる。
- Opus の最終確認（2026-11-02）への対応: F-H1（`:reclaim-focus` の予約を「focus が stray になった瞬間」にも拡大。アクティブにして戻した最小化の窓は、元の WS ではなく**現在の WS** へ）、
  F-M1（修飾キーが押されている間は Alt を注入しない。拒否は `:reclaim-focus` の再試行に任せる）、F-M2（起動時は `recover-strays` を `adopt-existing!` の前に）、
  F-M3（最大化した窓は取り込んでから最大化し直す）、F-M4（再 park を諦めた窓は `:refresh` でも park しない）、F-L1（壊れた sink の作り直し）、F-L2（最小化→復元の手を削除）、
  F-L3（`:refresh` は reclaim の記録を消さない）。
- **sink の前面化は Alt の注入（`SendInput`）に依存する**（ホスト型で、UI スレッドからの単独の `SetForegroundWindow` は拒否された）。修飾キーが物理的に押されているときは注入しないので、その間は拒否になる。実機は未検証。
- `[:window-surfaced id]`（改訂 5b）は実装済み: 再 park を諦めた窓はフロートとして可視ワークスペースに加わり、以後 `goto` のたびに付いてくる。未対応: 全画面の窓は画面に残る（M5、D-5 に記録）。実機は未検証。

## 改訂 5（2026-11-02。提案。Opus の最終確認 F-M4 と実装後レビュー M3 の残り: `[:window-surfaced id]`）
- 問題: アダプタは、可視でないワークスペースの窓が何度 park しても画面に戻ってくる場合（会議アプリが自分で前面に出る、ユーザーが明示的に出している）、`repark-limit`（3 回）で諦める。
  諦めた窓は Core では可視でないワークスペースのままなので、P-1 が恒常的に破れ（画面には見えているが Core は隠れていると信じる）、`goto` で戻ってくるたびに再び争う恐れがある。
- 決定: 新しい観測 event **`[:window-surfaced id]`**（「この窓は可視でないワークスペースにあるはずだが、画面にあり続けている。ユーザー/アプリの意思とみなす」）。Core は、`id` が既知で、
  現在のワークスペースにないとき、その窓を**現在のワークスペースへ移す**（`ws/append`。位置は末尾、フォーカスは動かさない。フロートの印はそのまま）。**silent**（`:focus` を出さない。E3 の拡張）。
  効果は既存の差分から導かれる: 現在のワークスペースに入ったので `[:show id]` とタイルなら `[:place …]`。現在のワークスペースにいる／未知の窓なら何もしない（冪等）。
  `:os-focus`・`:external-focus`・`:pending-focus`・`:stray-own` には触れない（観測だけが external を下ろす: E10）。
- アダプタ: 諦めた時点（`compare-placements` の上限到達）で `[:window-surfaced id]` を流す。`gave-up` の印は、直後の `[:show id]`（`show` が消す）で下りる。
- 不変条件 **S-1**: `window-surfaced` の結果、`id` が既知なら現在のワークスペースにあり、他のワークスペースにはない（各窓はちょうど 1 つのワークスペースに属する: I1）。未知の id・不正な id・既に現在のワークスペースの窓は、
  状態を変えない。`:focus`／`:focus-none` を出さない（F12c）。`:external-focus` を下ろさない（E10）。
- 採らなかった案: 諦めずに常に戦う（ちらつき）。`:follow` のように、その窓のワークスペースへ `goto` する（ユーザーの現在の作業を奪う）。窓を最小化する（アプリの意思に反する）。

### 改訂 5b（2026-11-02。Opus の確認 R5-M1〜M3・L1〜L4 を反映。5 と食い違う点はここが優先）
- **浮上した窓はフロートとして迎える（R5-L1）**: `window-surfaced` は、窓を現在のワークスペースへ移し、**フロートにする**（既にフロートならそのまま）。アプリが勝手に出した窓をタイルに組み込んで、
  作業中のレイアウトを崩さない。タイルに戻したければ `:toggle-float`。`:current`・`:os-focus`・`:external-focus` には触れない。S-1 に「`[:show id]` を含む」「`:place` を出さない（フロート）」を足す。
- **「諦めた」状態は窓の寿命まで保つ（R5-M2）**: アダプタの `gave-up` は `[:show]`・`[:place]` では消さず、`window-removed` でだけ消す。`hide` が `gave-up` の窓を受けたら、park せず、
  代わりに `[:window-surfaced id]` を流す（R5-M3。Core は冪等）。これで、その窓は `goto` のたびに「現在のワークスペースの窓」へ移り続け（xmonad の `copyToAll` に近い）、毎回争うことがない。
  Core に sticky の概念は足さない（再送で足りる。1 回の `goto` につき余分な往復が 1 つ増えるだけ）。
- **上限は時間窓つき、環境の変化は数えない（R5-M1）**: 再 park の連続 `repark-limit`（3）回は、**最初の再 park から 30 秒以内**に限る。30 秒を過ぎたら 0 から数え直す。
  同じポーリングで park した窓が**2 つ以上**画面に戻っていたら、環境（画面構成の変化・スリープ復帰・RDP）とみなし、数えずに park し直す。unverified on Windows。
- **ユーザーの明示操作とアプリの自発の区別（R5-L2）**: 区別は設けない。再 park は前面の窓を除外するので、ユーザーがタスクバーで選んだ窓は前面である間は数えられず、D-7 の reclaim で
  フォーカスが戻された後に初めて数え始める。つまり浮上には「reclaim → 再 park」の繰り返しが要る。`:follow` の設定では、そもそも浮上ではなく `goto` になる。
- **実装の注意（R5-L3）**: 浮上の dispatch は `spawn` で後回しにする（`compare-placements` のループの中で effect を実行しない）。
- テスト（R5-L4）: S-1 のプロパティテスト（既知・未知・現在のワークスペースの窓・フロート）、アダプタ: 上限到達で 1 回だけ流れる／`gave-up` の窓への `hide` で再送される／同時に複数戻った窓は数えない／30 秒後に数え直す。

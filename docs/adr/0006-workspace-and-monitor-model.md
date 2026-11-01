# 0006. ワークスペースの実装方式とモニタモデル

- 状態: Accepted（改訂 3: 案 2 に決定。Opus レビュー 1 回の High 3・Med 5 を反映。Core の hide/show・アダプタの park・回復を実装し、ホスト型 Windows（Server 2022 と Server 2025）の契約テスト 45 項目で検証済み。実機（Windows 11、空の専用デスクトップのみ）で基本の動作を確認。Opus の実装後の再確認（2026-11-01、High 3・Med 8）の指摘に対応中）
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

### D-7 可視ワークスペースが空になったら、OS のフォーカスを管理窓から外す（H3。新しい effect `[:focus-none]`）
- 問題: 空のワークスペースへ `goto` すると、画面には何も無いが、前面の窓は park された（画面外の）窓のまま。打鍵は見えない窓に入る（ターミナルならコマンドが実行される）。
  最後の窓を `send` したとき、最後の窓を閉じたとき（Windows は Z 順の次の窓＝park 済みの窓へフォーカスを渡しうる）も同じ。xmonad では、空のワークスペースのフォーカスはルート窓で、打鍵はどこにも入らない。
- 決定: 新しい effect **`[:focus-none]`**。Core は、遷移の結果 `vis(new)` が空で、`silent?` でなく、かつ次のどちらかのとき出す。
  1. `:current` が変わった（`goto`、`send` で現在のワークスペースが変わる場合ではなく `goto-tag`／`shift` 系）。
  2. 旧の state が `external?` でなく、旧の `vis` が空でなかった（最後の窓が閉じた・送り出された）。
  ユーザーが管理外の窓（スタートメニューなど）を使っている間に、背景で管理窓が閉じても、フォーカスを奪わない（旧が external なら 2 は出ない）。
- 不変条件 **F12**: `[:focus-none]` と `[:focus id]` は同じ effect 列に同時に出ない。`[:focus-none]` は `vis(new)` が空のときだけ出る。遷移が無い（state が変わらない）ときは出ない。
  順序は `hide` → `show` → `place` → `focus`／`focus-none`（最後）。
- アダプタ: ポート `:focus-none` は Jwno の `(:set-focus-to-desktop wm)`（win.janet:3669）を呼ぶ。ポートが無い／失敗した場合は何もしない（ランタイムは各ポートを protect する）。
  **unverified on Windows**: デスクトップ（Progman）への SetForegroundWindow が前面ロックで拒否されうる。そのときは、少なくとも park 済みの窓にフォーカスが残る状況は変わらない（現状と同じ）。
  結果として届く `focus-changed`（デスクトップの hwnd）は、管理外の窓として `external` を立てる（E 系の既存の扱い）。R-10 の再主張は `:focus` だけが対象なので、`focus-none` を再主張しない。
- 検討して採らなかった案: 空のワークスペースの代わりに「ダミーの透明窓」を作る案（窓を1つ増やす割に利点が少ない）。park した窓に `WS_EX_NOACTIVATE` を足す案（Jwno の transform の外で窓のスタイルを書き換える）。

### 実装の順序
1. 本節のレビュー（Opus）。2. Core: `visibility-effects` の `shows`、`focus-none` の導出、`effect-rank`、不変条件の更新（`docs/INVARIANTS.md` の H-b・H-c・F12）、`test/update-test.janet`・`test/property-test.janet`（H-c のミラーと F12 を生成器に加える）。
3. ランタイム: ポート `:focus-none` の実行。4. アダプタ: ポートの実装と契約テスト（unverified on Windows の注記付き）。

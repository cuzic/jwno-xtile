# Invariants of the core

状態: **Draft — 人間の承認待ち。** ここに書かれた性質が「仕様」であり、テストはこれを
参照する。承認前は、テストが通ることは仕様が正しいことを意味しない（ADR 0003）。
`test/property-test.janet` の ID（I*/E*）と対応する。

## State
- I0 状態は不変データのみ（table / array / buffer を含まない）。
- I1 どのウィンドウも、全ワークスペースを通じてちょうど 1 か所にしか存在しない。
- I2 各ワークスペースで、空ならフォーカス無し、非空ならフォーカスは必ずそこにあるウィンドウ。
- I3 `nmaster >= 0`、`0.1 <= ratio <= 0.9`。
- I4 `current` は `tags` のどれか。

## Geometry（可視ワークスペース、`state.screen` 基準。負の座標・オフセットを含む）
- I5 配置はウィンドウ数と同数。
- I6 各矩形は画面内、幅・高さ > 0。**既知の制限**: ウィンドウ数が画面ピクセル数を
  超えると幅 0 になりうる（現実的でないため未対応。ADR 0007 で扱う）。
- I7 Full 以外: 矩形は重ならず、面積の総和が画面面積と一致（隙間なし）。

## Effects
- E1 `:place` の矩形は新しいモデルの配置と一致する。
- E2 `:focus` の対象は新しいモデルのフォーカスと一致する。
- E3 エコー抑制: `:focus-changed` / `:desktop-changed` は `:focus` を返さない。
- E4 フォーカス完全性: 非サイレントなイベントで、external でない可視ワークスペースの
  フォーカスが変わったら `:focus` を返す（external 中は返さない: E11）。
- E12 破壊的操作（`:close` `:send`、並べ替え）は、モデルのフォーカスが最後に観測した
  OS フォーカス（`:os-focus`）と一致するときだけ動く。対象 id は常に `:os-focus`。
  （旧 E5 を置き換え。`:focus` effect が失敗しても誤 close しない構造的保証）
- E6 冪等性: `window-opened/closed`, `focus-changed`, `desktop-changed`, `screen-changed`,
  `windows-observed` は 2 回目に state も effects も変えない。
- E7 ミラー: effects の `:place` だけを適用した画面は、常にモデルの配置と一致する。
- E8 `:refresh` は可視ウィンドウ全件の `:place` を再発行する（external は変えない）。
  ※モデル側のずれ（幽霊・所属違い）の回復は R4。
- E9 Core は入力の型・可変性・値域を検証し、不正なら無視する。どんな入力でも投げない。
- E10 `:external-focus` は観測だけが下ろす（`focus-changed` / `desktop-changed`、および
  `:os-focus` と同じ id の `window-opened`）。他のイベント・コマンド・`refresh` は下ろさない。
- E13 可視ワークスペースの管理ウィンドウへの `focus-changed` の直後は、`:close` がそのウィンドウを
  対象にする。未知 id への `focus-changed` の後に同じ id の `window-opened` が来ても同様。
- E11 external 中は、ユーザーが求めたフォーカス移動（`focus-*`, `goto`）以外で `:focus` を返さない。

## Observation / recovery（ADR 0005）
- R1 `focus-changed x` と `desktop-changed (tag of x)` は到着順に依存せず、同じ結果になる。
- R2 Core が出した `:place` の矩形をそのまま `window-moved` で返すと、effect は空。
  不一致が続く場合の再配置は有限回（3 回）で止まる。
- T2 起動・リロード時、`focus-changed x` と `windows-observed`（x を含む）は到着順に依存せず、
  どちらの順でも x がフォーカスされ、`:close` の対象になる。
- R4 `windows-observed` の後、モデルは観測されたウィンドウ集合とちょうど一致する。
  `:focus` を返さない。フォーカスは、すでに観測済みの OS フォーカスの採用以外では動かさない。並びの先頭が master。nil タグの既知ウィンドウは動かさない。

## xmonad 互換（ADR 0007）
- X1 `test/xmonad-model.janet`（StackSet.hs の転記）との差分テスト: insertUp, delete,
  focusUp/Down, swapUp/Down, swapMaster, shiftMaster, focusMaster が一致。

## classify / keymap（葉のモジュール。状態を変えない）
- C1 `classify` は全域: どんな rules・facts でも例外を投げず、:tile / :float / :ignore のいずれかを返す。
- C2 ユーザールールが先に評価され、最初に一致したものが勝つ。無効なルールは飛ばす。
- C3 組み込みの優先順位: ignore（不可視・ツール・最小化・フルスクリーン）> float（ダイアログ・オーナー付き）> tile。
- K1 キー文字列の正規形は、大文字小文字・空白・修飾キーの順序に依存しない。不正な文字列は nil。
- K2 `build` は例外を投げず、不正な束縛（不明なコマンド・引数の型違い・重複キー）を報告して除外する。
- K3 既定の xmonad 束縛は Alt／Win のどちらでも検証を通り、重複せず、`set-layout` と `shift-master`
  以外の全コマンドを網羅する。

## Floating / window-seen（ADR 0008。Draft）
フロートはスタックに残り、レイアウトに渡すときだけ除外される（xmonad と同じ）。I5〜I7 は
「タイル対象（スタック − `:floating`）について」と読む。
- C4 任意の rules・facts について、`hidden?(facts)`（不可視・最小化・フルスクリーン）ならば `classify = :ignore`。
- F1 `:floating` と `:misfit` のキーはスタック内のウィンドウだけ。`window-closed`／幽霊削除で消える（HWND 再利用）。
- F2 `:place` の id は `:floating` に含まれず、矩形は現在の配置と一致する（`nil = nil` では通らない）。
- F3 `window-seen` は E6（冪等性）の対象。
- F4 既知の id への `window-seen`（hidden でない facts）は state も effects も変えない（分類は管理開始時の 1 回）。
- F5 hidden になったウィンドウは、スタック・`:floating`・`:misfit` のどこにも残らない（`:os-focus` は観測なので残ってよい）。
- F6 `:toggle-float` の結果は、同じ facts の `window-seen` / `windows-observed` の再送で戻らない。
- F7 `placements(s)` は、全フロートを除いたスタックを arrange した結果と等しい。
- F8 `:os-focus` と同じ id が hidden になったら `:external-focus` が立ち、`:focus` は出ない。
- F9 `:toggle-float` はスタックの順序とフォーカスを変えず、2 回で元に戻る。
- F11 facts が dictionary でない `window-seen` は何も変えない。`windows-observed` の不正な facts は「facts 無し」と同じ扱い。
- R4（改）snapshot 後のモデル = 観測集合 − 有効な facts で hidden／ignore と判定されたもの。同じ id は最初の出現が勝つ。
- E10（追記）`window-seen` は `window-opened` と同じ条件でのみ external を下ろせる。hidden 遷移は external を立てる。
- K3（例外）`:toggle-float` は既定の束縛を持たない（xmonad の既定に toggle は無い）。
- 未実装: X1 の拡張（フロートを加えた参照モデルとの差分）。F7 が同じ性質を `ws/remove` 経由で検査している。

## Focus reassertion（ADR 0009。Draft、`test/property-test.janet` と `test/update-test.janet` で検査済み）
`:pending-focus {:target :tag}` は `:goto` コマンドが `[:focus f]` を出すときに立つ Core の state。
- Q1 `[:command :reassert-focus]` は、`:pending-focus` があり、`target` が可視ワークスペースの管理ウィンドウで、
  external が偽で、`:os-focus` がフロートでなく、`:os-focus ≠ target` のときだけ、モデルのフォーカスを `target` にして `[:focus target]` を出し、
  `:pending-focus` を下ろす。それ以外（pending 無し・不正な引数・external 中・`:os-focus = target`）は何も出さない。
- Q2 受理されたときの effects は `[:focus target]` だけ（`:goto :close :send :place` を出さない）。`:current`、
  `:external-focus`、`:os-focus`、レイアウト、並び、`:floating` は変わらない。E2・E4・E10・E11・E12 を維持する
  （`:os-focus` が `target` に一致するまで破壊的操作は止まる）。
- Q3 `:pending-focus` は、`:reassert-focus` 以外の任意の `:command`、`target` への `focus-changed`、`target` の除去、
  `:current` が `:tag` から外れること、非 silent な event による可視ワークスペースのフォーカス変更、
  `:reassert-focus` の受理、のいずれかで下りる（silent な `focus-changed` では下りない）。したがって再発行は 1 エピソードに
  つき最大 1 回で、下りた後の `:reassert-focus` は何もしない。
- Q6 `:os-focus` がフロートのとき、`:reassert-focus` は何も出さない。引数付きの `:reassert-focus` は何もしない。
- Q4 `:pending-focus` の `target` は常にスタック内の窓で、`:tag` は `:tags` のどれか（I1/I4 と並ぶ状態の整合）。
- Q5（E2 の拡張）全ての `:focus` effect の対象は `:current` のワークスペースの窓（Core が暗黙の `:goto` を起こさない）。
- K3（例外）`:reassert-focus` は束縛不可。keymap は `:internal` を含む未知の種類を拒否する（`case` の既定は拒否）。

## Workspace visibility（ADR 0006。`test/update-test.janet` と `test/property-test.janet` で検査済み）
`vis(s)` = 可視ワークスペースの窓、`all(s)` = 全ワークスペースの窓。
- H-a `[:hide id]` の対象は、新しい state で `all` にあり、`vis` に無い窓だけ（閉じた窓・ユーザーが最小化した窓・幽霊には出ない）。
- H-b（ADR 0006 D-6 で改訂）`[:show id]` の対象は、新しい `vis` にあり、旧の `vis` に無かった窓すべて（新規の窓や snapshot で追加された窓も含む。Core が忘れた park 中の窓が戻ってくるため）。
  逆に、可視に入った窓には必ず `:show` が出る。例外: `[:command :refresh]` は可視の窓すべてに `:show` を出し直す（取り残された窓の回復）。
- H-c ミラー: hide／show の effect だけを適用した「画面にある窓の集合」は、常に `vis(s)` と一致する（D-6 で、可視に直接現れた窓を「すでに画面にある」と仮定する項は不要になった。Core 内では定義の言い換えに近く、
  実質の検査はアダプタ側の P-1 が担う）。
- H-d 同じ窓に `hide` と `show` を同時に出さない。重複しない。`vis` に無い窓に `:place` を出さない（`:show` されるフロートにも `:place` は出ない）。
- H-e すでに隠れている窓に `hide` を出し直さない。ただし `:refresh` は、park を保つために、可視でないワークスペースの窓すべてに `hide` を出し直す。
- 順序: `hide` → `show` → `place` → `focus`（`:goto`／`:send` が先頭）。

## OS のフォーカスと park した窓（ADR 0006 D-7、改訂 4c〜4e）
`stray(s)` = `:os-focus` が、Core が知っている窓で、可視でないワークスペースにある。`:os-focus` が無い／未知の窓は stray ではない。
- F12a（活性）非 silent で状態が変わる遷移（`:command` では `:current` か `vis` が変わるもの）の結果、`stray` なら、`[:focus id]` か `[:focus-none]` のどちらかが effect に含まれる。
  `:reclaim-focus` は、試行が上限未満なら、`stray` のときちょうど 1 つ（印付き `:reclaim`）を出す。
- F12b（奪わない）`:os-focus` が無い／未知の窓／可視の窓なら、印付き effect も `[:focus-none]` も出ない。
- F12c silent な event（`focus-changed`、`windows-observed`、`desktop-changed`）の直接の結果に `[:focus-none]` は含まれない（回復は `:reclaim-focus` が担う）。
- F12d `[:focus-none]` と `[:focus id]` は同じ effect 列に同時に出ない。`[:focus-none]` は可視ワークスペースが空のときだけ。
- F12e（収束・試行）`:reclaim-focus` が effect を出すのは、同じ窓について連続 3 回まで。4 回目に `[:notify :reclaim-gave-up id]` を 1 度出し、以降は何も出さない。
  `:reclaim-tries` は `{:id :n}`。`:os-focus` が可視または管理外・nil になる、`:reassert-focus`／`:reclaim-focus` 以外のコマンド、窓の消滅でリセット。
- 改訂: **E11** は、`stray` のときの `:focus` を例外とする。**Q3** は `:reclaim-focus` を `:reassert-focus` と同じく例外とする（`:pending-focus` を消さない）。
  **E6** は、`stray-focus` を足すのは「状態が変わった」遷移に限る。`goto` は `:os-focus` を消さない（観測は事実）。`:stray-own {:id}` は自分の `goto`／`send` で前面に残った窓の印で、
  `:follow`（`:stray-mode`）はこの印のある窓には反応しない。印は、その id 以外の `focus-changed` または任意のコマンドで下りる。
- P-1（アダプタ側。タイマーと `:reclaim-focus` を流し切った後に成り立つ）Core の `vis(s)` の窓は画面上にある（`parked` に無い）。可視でないワークスペースの窓は park されているか最小化されている。
  前面ロックで拒否されたとき（3 回で諦める）は正当に破れる。フェイク OS のプロパティテストで検査する（未実装）。
- M4（Opus M4）最小化／全画面で `drop-hidden` された窓は、元のタグを `:hidden-from {id tag}` に覚え、同じ id が（タグ無しで）戻ったらその窓は元のワークスペースに戻る。明示のタグは優先する。
  OS が snapshot からその id を完全に失ったとき、`window-closed` のとき、再び現れたときに覚えを消す（id は再利用される）。

## 複数モニタ（ADR 0012）
- M-0（段階 1a、実装済み）`(s :current)`／`(s :screen)` の読み書きは `st/current`・`st/screen`・`st/set-current`・`st/set-screen` だけを通す。
- M-4（実装済み）モニタが 1 つのとき、新しい Core は凍結した旧 Core（`test/reference/core-v0/`）と、全ての event の `:state`（`st/current`・`st/screen` で射影）と `:effects` が一致する（`test/core-v0-test.janet`）。
- M-1（段階 1b、実装済み）`:current`／`:screen` は State に無く、`:screens` と `:focused-screen` から導く（`st/current`・`st/screen`）。`:focused-screen` は範囲内。
- M-2（実装済み）各ワークスペースは高々 1 つのモニタに見える。
- M-3（実装済み）`vis(s)` は全モニタの見えているワークスペースの窓の和集合（`st/vis-ids`）。`:hide`／`:show`／`:place` はそれに対して導かれ、配置はモニタごとにそのモニタの矩形で計算される（I5〜I7 はモニタごと）。
- 判定の書き換え（ADR 0012 の表）: `stray-id`・`window-dragged`・`open-window` の採用・`windows-observed` の採用・`window-surfaced` は「どれかのモニタに見えているか」で判定する。`focus-window` は、見えている窓なら
  `:focused-screen` をその窓のモニタへ移し、external を下ろす。`goto` は `greedyView`（見えていれば入れ替え）、`:view` は見えているモニタへフォーカスを移すだけ。`[:focus-none]` は「フォーカスのあるモニタのワークスペースが空」のとき（F12d の改訂）。
- 2 モニタの state は、プロパティテストの生成器の 3 分の 1 に入る（`test/property-test.janet`）。

## gap と padding（ADR 0013）
- G-1 gap = padding = 0 のとき、`placements` は xmonad の `arrange` と完全に同一（凍結した旧 Core との差分テストの対象）。
- G-2 全ての矩形は padding で縮めた画面の中にあり、`pos?`、互いに重ならない（Full を除く）。G-3 隣接するタイルの間の距離は `gap`（縮め切れない小さい矩形を除く）。
- G-4 I7（隙間なく覆う）は gap = padding = 0 のときだけ成り立つ。縮め方: `inner` の境界上にない辺だけ、左・上は `ceil(gap/2)`、右・下は `floor(gap/2)`。逆変換（辺を戻す）は `arrange inner` に一致する（F7 の書き換え）。
- 設定: State の `:gap`／`:padding`（0 はキーを置かない）。`set-gap`／`set-padding`／`inc-gap`／`dec-gap` は 0〜200 の整数だけを受け、モニタごとに `min(w,h)/8` へ丸める。

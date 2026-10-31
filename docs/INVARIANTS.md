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

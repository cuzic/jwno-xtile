# 0007. xmonad 互換の範囲と「管理対象ウィンドウ」の定義

- 状態: Accepted（Opus レビュー 5 回で収束、2026-10-31。管理対象ウィンドウの定義 (3) は未決のまま）
- 日付: 2026-10-31

## Context

「xmonad ライク」を掲げるが、どこまで xmonad と一致させるかを決めていなかった。実際、
最初の実装は `insertUp`（フォーカス位置に挿入）と `swapMaster`（master との入れ替え）が
xmonad と違い、`shiftMaster` の動作だった（レビューで発覚、StackSet.hs の原文で確認し修正済み）。
また「どのウィンドウをタイルするか」が未定義で、最小化・フルスクリーン・ダイアログの扱いが
state の形に影響する。

## Decision

1. **互換の範囲**: `StackSet` のスタック操作（insertUp, delete, focusUp/Down, swapUp/Down,
   swapMaster, shiftMaster, focusMaster）と、Tall／Wide（= Mirror Tall）の矩形計算
   （`splitVertically` の端数配分＝後ろの要素に寄せる、`splitHorizontallyBy` の `floor`）は
   xmonad と**厳密に一致**させる。スタック操作は独立した参照モデル `test/xmonad-model.janet`
   （StackSet.hs の転記）との差分テストで担保する（X1）。矩形計算は `Layout.hs` を確認して
   合わせ、例示テストで固定した。
2. **意図的な差異**（理由付き。ここに無い差異はバグとして扱う）:
   - (a) 他ワークスペースのウィンドウへの OS フォーカス通知で、ワークスペースを切り替えない
     （xmonad の `focusWindow` は切り替える）。理由: 仮想デスクトップの切替は OS が起こし、
     Core は `:desktop-changed` で追従する。1 つのずれたウィンドウにビューを引きずらせない（ADR 0005）。
   - (b) 管理外フォーカス中、および最後に観測した OS フォーカスとモデルのフォーカスが食い違う間は、
     close／send／並べ替えを no-op にする。xmonad には
     この概念が無い。理由: データ損失の防止（ADR 0005）。
   - (c) `ratio` の範囲を [0.1, 0.9] にする（xmonad の Tall は [0, 1]）。理由: 実用上、
     極端な値でウィンドウが消えるのを避ける。
   - (d) `swap-master` 等も (b) と同じく、観測済みフォーカスと一致しない間は何もしない。
   - (e) external 中は新しいウィンドウにフォーカスを移さない（xmonad の manage は必ず移す）。
     ダイアログからフォーカスを奪わないため。
   - (f) `:goto`・フォーカス移動・`:close` の後など、OS がフォーカスを確認するまでの間は
     破壊的操作が黙って no-op になる。xmonad には無い（ADR 0005）。無視したことをユーザーに
     知らせる手段（ログ／ビープ）は Shell の検討事項。
   - (g) 分類は管理開始時の 1 回のみ（manageHook と同じ）。後からは hidden への遷移だけ反映（ADR 0008）。
   - (h) Full は全タイルを重ね、見える 1 枚は Shell の z 順に依存する（xmonad はフォーカスの 1 枚）。
   - (i) fullscreen は管理から外す（xmonad の `doFullFloat` は管理したままフロート）。
   - (j) ドラッグ／リサイズした窓はフロートになる。xmonad の `mouseMoveWindow`/`mouseResizeWindow` が `float` を呼ぶのと一致する（差異ではない）。ただし Windows ではタイトルバーの
     ドラッグという日常の操作で起きるため、矩形が配置と違うときだけフロートにする（ADR 0008, 0010 D9）。
   - (k) 最大化したタイルはフロートになる（`doFullFloat` に近い）。スナップ・アプリ自身の移動・外部ツールの変更は、ポーリングの間隔だけ遅れて Core の配置に戻る。
   X1 の差分テストは workspace レベルのみで、`update` レベルの (a)(b) は例示テストと
   プロパティ（E5/E10）で担保する。
3. **管理対象ウィンドウの定義**（未決）: 判断は純関数
   `(classify facts) -> :tile | :float | :ignore` とし、`facts` は Shell が集める事実
   （クラス名・exe・ダイアログか・最小化か・フルスクリーンか）のデータ。実装は今後。
4. **既知の制限**: ウィンドウ数が画面ピクセル数を超えると幅 0 の矩形が出る（I6）。
   現実的な個数では起きないため当面扱わない。
5. Jwno の設定リロードで Shell 保持の state が消える。起動時の列挙（`[:window-opened id tag]`
   の列に変換するだけ。流す順序が master の決定に直結する）で再構築する。順序・タグ・
   レイアウトパラメータの喪失は許容するか、永続化するかは未決。

## Consequences

- xmonad ユーザーの期待と一致する。互換性の主張はテストで裏付けられる。

## Confirmation

- `test/model-test.janet` が通る。意図的な差異を入れる場合は本 ADR を先に更新する。

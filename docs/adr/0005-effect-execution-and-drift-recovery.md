# 0005. 観測原則・effect の実行規約・実画面とのずれの回復

- 状態: Accepted（Opus レビュー 5 回で収束、2026-10-31。Core 側は実装・検証済み。Shell 規約 1〜7 は未実装・Windows 未検証）
- 日付: 2026-10-31

## Context

Core は新旧 state の差分から effect を導出する（ADR 0001）。この方式は、実画面や OS の
状態が Core の想定とずれたときに、自力では気づけない。現実のずれの原因:
(a) `SetForegroundWindow` がフォアグラウンドロックで失敗する、(b) ユーザーがウィンドウを
ドラッグした／アプリが自分でサイズを変えた／Jwno が retile した、(c) 仮想デスクトップ間の
移動 API が失敗する、(d) `:window-removed` の取りこぼし（Jwno は管理対象にしか発火しない）。
さらに Jwno の通知は非同期で順序が保証されず、**新しいウィンドウでは未知の hwnd への
`:focus-changed` が `:window-created` より先に届き**、同じ hwnd への連続したフォーカス通知は
重複排除される（`~/jwno-xtile-ref/jwno/src/win.janet` で確認）。
最悪の失敗は **ユーザーが見ていないウィンドウを `:close` で閉じる**こと（保存前のデータ損失）。

## Decision

### 1. 観測原則（実装済み）

OS についての事実は観測イベントからのみ入り、**Core は自分の effect が成功したと仮定しない**。

- `:os-focus` = 最後に観測した OS フォーカス（有効な id なら、未知のものや別ワークスペースの
  ものでも記録する）。不明なら無い。
- **破壊的操作（`:close` `:send` と並べ替え系）は、モデルのフォーカスが `:os-focus` と
  一致するときだけ動く**（"actionable"）。これは「ユーザーが見ているものにしか作用しない」を
  構造として保証する。`focus-next` 等でモデルのフォーカスだけが先に進み、`:focus` effect が
  失敗しても（OS は別のウィンドウのまま）、OS が確認するまで `:close` は何もしない。
  不変条件 E12。
- `:external-focus`（OS のフォーカスが管理外にある）は **フォーカスを奪わないための**ガード:
  立っている間は `:focus` effect を導出しない（ダイアログからフォーカスを奪わない）。
  観測だけが立て・下ろす（`focus-changed`、および後述の `window-opened` の採用）。
  明示のフォーカス移動コマンドと `:goto` は、ユーザーの要求として常に `:focus` を出す。
- `[:focus-changed id]`: 可視ワークスペースの既知ウィンドウならモデルを更新し external を
  下ろす。他ワークスペースの既知ウィンドウ／未知の id は `:os-focus` に記録して external を
  立てる。nil／不正は `:os-focus` を消して external を立てる。
- `[:window-opened id]`: 新しいウィンドウを可視ワークスペースに追加した時、`id` が
  `:os-focus` と一致するなら、その観測を採用して external を下ろす（Jwno は未知 hwnd の
  フォーカスを `window-created` より先に報告し、繰り返さないため）。
- `[:desktop-changed tag]`: `:current` を変える。`:os-focus` が新しいワークスペースにあれば
  採用し、無ければ `:os-focus` を消して external を立てる（古い観測は信用しない）。
  `focus-changed` と `desktop-changed` は **到着順に依存しない**（プロパティ R1）。
- `:current` を変えてよいのは `:desktop-changed` と `:goto` だけ。`:goto` は `:os-focus` を消す
  （OS が確認するまで破壊的操作を止める）。
- `[:window-closed id]`: そのウィンドウのフォーカス記録と `:misfit` を消す（HWND は再利用される）。

### 2. 回復の語彙（実装済み）

- `[:command :refresh]`: 可視ワークスペースの全 `:place` を再発行。`:focus` は external でない
  ときだけ。external・`:os-focus` は変えない。
- `[:window-moved id observed-rect]`: 観測矩形がモデルと一致すれば何もしない（自分の `:place`
  のエコーを止める）。不一致なら `:place` を再発行する。同じ目標矩形に連続 3 回不一致なら
  諦める（最小サイズを強制するアプリ対策）。目標が変われば数え直し、`:refresh` と close で消える。
  諦めたウィンドウの扱い（float 化など）は ADR 0007 の `classify` と接続する（未決）。
- `[:windows-observed [[id tag-or-nil] ...]]`: OS の実在ウィンドウのスナップショット。
  **純粋にウィンドウ集合の観測**であり、`:focus` を返さない（サイレント）。観測済みの OS フォーカスを採用する場合を除きフォーカスを動かさない。具体的には、
  すでに観測済みの `:os-focus` が可視ワークスペースのウィンドウになった場合に限り、その観測を
  採用する（起動時に「フォーカスを先に観測 → スナップショット」の順でも、逆順でも結果は同じ。
  `window-opened` と同じ扱い）。
  並びの先頭が master（topmost）。既知のウィンドウの順序は変えない（順序に意味があるのは、
  空のワークスペースへ入れる起動時・リロード時だけ）。tag が nil は
  「デスクトップ不明」で、既知のウィンドウはそのまま、未知のものは可視ワークスペースに追加する。
  幽霊 ID の削除（結果としてモデルのフォーカスが動いても、`:os-focus` と一致するまで破壊的操作は止まる）、
  所属の修正も行う。
- 失敗した effect: Shell は握りつぶさず、一定時間後に `:windows-observed` と `:refresh` を
  1 回ずつ積む。失敗を専用イベントで返すかは、実機で必要性が出てから決める（未決）。

### 3. Shell の規約（**未実装**。Shell を書く時の必須条件。Windows 未検証）

1. `update` の結果の state を **保存してから** effect を実行する。
2. effect 実行中に届いたイベントはキューに積み、1 つずつ処理する（再入禁止）。
3. Shell は `update` を `protect` で囲む。
4. **`:focus` / `:goto` を実行した後、および `:desktop-changed` を流した後は、Shell 自身が
   `GetForegroundWindow` で実際のフォーカスを観測し `[:focus-changed hwnd]` を流す。**
   Jwno の通知は重複排除されたり、デスクトップ切替の途中で nil が挟まったりして届かない
   ことがあるため、Jwno の通知だけに頼らない。届かない間の不便（`:close` が効かない）は
   安全側の失敗として許容する。
5. `window-moved` に載せる矩形は **`:place` と同じ座標系**にそろえる（Windows 10/11 では
   `GetWindowRect` が DWM の見えない枠を含むため、枠を除いて比較する）。送るのは移動・
   リサイズの**終了時**（`EVENT_SYSTEM_MOVESIZEEND`）とアプリ起因の変更のみ。ドラッグ中の
   `LOCATIONCHANGE` を流すと、Core がドラッグ中に引き戻して喧嘩になる。
6. 起動時の列挙は `[:windows-observed ...]` 1 回で表す（順序が master を決める）。
7. **破壊的コマンドの直前に、事実を新しくする**（観測の遅れ・欠落への対策。Core は判断時点の
   事実を自分で確かめられない）:
   1. （ADR 0009 でさらに全 `:command` に拡大）`:close` `:send` と並べ替えのコマンドを Core に渡す直前に、Shell が `GetForegroundWindow` を
      観測して `[:focus-changed hwnd]` を先に流す（キー入力は低レベルフックで即座に届くが、
      フォーカス通知は UIA で非同期のため、キューの上で逆順になりうる）。
   2. `[:close id]` を実行する直前に、`GetForegroundWindow` がその id と
      **完全一致**することを確かめ、違えば捨てる（所有者へは寄せない: owned ダイアログは ADR 0008 で
      管理対象のフロートなので、所有者を閉じると見ていないウィンドウを閉じる。ADR 0009 で改訂）。OS 境界での成否確認なので Shell に置いてよい（ADR 0001）。
   3. 無視した場合は、ユーザーに分かる形（ログ／ビープ）で知らせる（検討事項）。

### 4. その他

- effect の順序: `[:goto]` を先頭、配置、最後に `:focus`。ちらつきは実機で見直す（未検証）。
- 冪等性: `window-opened/closed`, `focus-changed`, `desktop-changed`, `screen-changed`,
  `windows-observed` は 2 回目に state・effect が変わらない（Windows は通知を重複させる）。
- Core は不正な入力を入口で検証して無視する。タグは文字列で、`st/make` が検査する。

## Considered Options

- 宣言的 reconcile（Core が常に望む全状態を返し、Shell が実状態と比較して適用）:
  回復は強いが、実状態の取得が Shell の責務になる。`windows-observed`＋`refresh` で
  同等の利点を Core 側で安く得る。足りなければ移行する。

## Consequences

- 良い: **Core 内部の仮定**（自分の `:focus` が成功したはず）による誤 close を、構造（actionable）で
  防ぐ。プロパティ E12/E10/E11、`:focus` を全部捨てるシミュレーション、順序入れ替え（R1/T2）で検査している。
- 注意: **観測の遅れ・欠落**（Alt-Tab 直後の close、UIPI で見えない昇格ウィンドウなど）には、
  Core は原理的に対処できない。`:os-focus` は「今のフォーカス」ではなく「最後に受け取った観測」であり、
  この種の誤 close は上記プロパティでは検査されない。Shell 規約 7（直前の再観測と実行直前の確認）で
  防ぐ予定で、**未実装かつ Windows 未検証**。
- 悪い: 観測が届かない間は `:close` 等が効かない（安全側）。頻度は Shell 規約 4 の
  `GetForegroundWindow` 観測が機能するかに依存し、**Windows では未検証**。
- 悪い: `:refresh`／`:windows-observed` を自動で呼ぶ契機は Shell に残る（OS 境界の分岐）。

## Confirmation

- プロパティテスト E3〜E13, R1（順序入れ替え）, R2（エコー）, R4（スナップショット）、
  S1〜S9 の回帰テストが通る（実装済み）。
- Shell 実装時、規約 1〜7 をフェイク Jwno のテストで検査する。特に「close キーとフォーカス通知を
  逆順に届けても、誤 close しない」を必須項目にする。実機で規約 4・5・7 を確認する。
- スパイク（ADR 0004）で、Jwno 自身の `:set-focus`／`:activate` との競合を確認する。

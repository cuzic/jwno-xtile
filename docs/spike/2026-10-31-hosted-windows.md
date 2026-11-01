# スパイク記録: GitHub ホスト型 Windows ランナー（2026-10-31）

実行: `spike-jwno` ワークフロー（run 41185349823 の 1 つ後の成功実行。`.github/workflows/spike-jwno.yml`、
`spike/probe-os.ps1`、`spike/probe-config.janet`、`spike/run-jwno.ps1`）。

**適用範囲に注意**: Windows Server 2022 Datacenter（10.0.20348）、セッション 2、explorer 動作、
1024×768、モニタ 1 枚。**ユーザーの Windows 10/11 デスクトップではない**。ここで確認できたことは
「ホスト型ランナーでは起きた」であり、実機（Windows 11 等）の保証ではない。

## 確認できたこと
| 項目 | 結果 |
|---|---|
| Jwno 0.9.16 のビルド | 成功（約 1 分）。ADR 0004 参照 |
| Jwno の起動 | 成功。インタラクティブなデスクトップがあり、UIA・フックが動く。ログに警告・エラー無し |
| フック発火の順序 | 新規ウィンドウで `:filter-window` → `:window-created`（同一ミリ秒）。起動直後に `:focus-changed` が 1 回 |
| `GetWindowRect` と DWM の見えない枠 | 実測で `[左 7, 上 0, 右 7, 下 7]` px（`DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS)` との差）。ADR 0005 §3-5 の想定どおり |
| 公開 COM `IVirtualDesktopManager` | `GetWindowDesktopId` と `IsWindowOnCurrentVirtualDesktop` は動く |
| 仮想デスクトップの作成 | `Win+Ctrl+D`（`keybd_event`）で作成・切替できた。レジストリ `VirtualDesktops` が現れ（初期は無し）、`VirtualDesktopIDs` は 32 バイト（2 個）に |
| Jwno のデスクトップ列挙 | `get-all-desktops` が 2 件を返した。デスクトップ 2 上の窓の `desktop-info` は `{:id ... :name (:default 2)}` |
| フォアグラウンドロック | **条件付き**。新しく作ったデスクトップ 2 では、別プロセスからの `SetForegroundWindow` が `False` でフォアグラウンドも動かなかった（run 1）。デスクトップ 1 では Alt なしでも常に `True` で成功した（run 2） |
| `:window-removed` の遅延 | 強制終了した窓は、フォーカス変化が無い間（5 秒）通知されず、**次の実際のフォーカス変化の直前**に出た（run 2 のシナリオ 6） |

## シナリオ（run 2、デスクトップ 1、`spike/run-jwno.ps1`）
時刻は Jwno と PowerShell で同じ epoch 秒（`os/clock :realtime`、刻みは約 15.6ms）。同一ティック内の順序は
`hooks.log` の行順が正（単一スレッド）。

| 観測 | 結果 |
|---|---|
| 新規ウィンドウ 3 枚のフック順（生の行順） | A: `filter-window → window-created → window-activated → focus-changed`。**B: `focus-changed → filter-window → window-created → window-activated`**（フォーカス通知が先）。C: A と同じ順。**順序は一定でない** |
| 実際のフォーカス移動 | `focus-changed` の直後に `window-activated`（管理対象の窓）。1 回の移動につき各 1 回 |
| すでに前面の窓へ `SetForegroundWindow` | 通知なし（重複排除を確認） |
| 30ms 間隔で B→A→B→A | 4 回の切替に対し通知は **2 件**。しかも最初の通知（hwnd=B）の時点で `GetForegroundWindow` は既に A。**通知は欠落し、遅れる** |
| 手動で窓を動かす | Jwno は自分では戻さない |
| `retile`（`jwno.exe -x retile` で REPL 経由） | 手動で動かした窓を含め、全窓が枠に戻った |
| Jwno の配置の矩形 | 3 枚とも `window=(-7,0,1031,735)`、見える枠 `(0,0,1024,728)`。**Jwno は DWM の枠（左右 7px・下 7px）を補正して置く**。タスクバー分（下 40px）は作業領域から除かれる |
| 強制終了した窓 | フォーカス変化が無い 5 秒間は `window-removed` なし。次のフォーカス変化の**直前**に `window-removed → focus-changed → window-activated` |
| 前面の窓を閉じる | 同一ティックで `window-removed(閉じた窓) → focus-changed(次の窓) → window-activated` |
| 起動時 | Jwno はランナー自身のコンソール（`hosted-compute-agent`）も管理対象にした。`get-all-desktops` は仮想デスクトップ未作成だと `@[]` を返すが、窓の `desktop-info` は `{:id ... :name :default}` が付く |

## 確認項目 5: Jwno 自身のフォーカス操作と Core の `:focus` の競合（run 3、デスクトップの往復）
`spike/probe-config.janet` が、ウィンドウマネージャの `:set-focus-to-hwnd` / `:set-focus-to-desktop` を
インスタンス上でラップし、Jwno が**自分で**フォーカスを動かした瞬間を記録した。

| 場面 | 観測 |
|---|---|
| 外部のフォーカス移動・`retile` | Jwno は自分ではフォーカスを動かさない（`jwno-set-focus-*` なし）。`window-activated` のみ |
| 新しく作った（Jwno のレイアウトが無い）デスクトップへ切替 | `virtual-desktop-changed`（layout=nil）のみ。Jwno は何も focus しない |
| Jwno のレイアウトがあるデスクトップへ**戻る** | `virtual-desktop-changed`（切替から数 ms 以内）→ **約 15〜30ms 後に Jwno が `set-focus-to-hwnd`**（自分が覚えている現在のウィンドウ B2）→ `focus-changed`。この時 OS 自身が選んでいた前面は **C2** で、Jwno の選択（B2）と違った |
| 戻った直後（約 100ms）に Core 相当の `SetForegroundWindow(C2)` | **負けた**。`SetForegroundWindow` は `True` を返したが、100ms 後も 3 秒後も前面は Jwno の選んだ B2 のまま |
| 戻った約 170ms 後 / 約 600ms 後に同じ操作 | **勝った**（前面が C2）。Jwno の `set-focus` はそれより先に済んでいた |
| 別デスクトップのウィンドウへ `SetForegroundWindow` | **Windows が自動でそのデスクトップへ切り替えた**（約 25ms 後に `virtual-desktop-changed`）。その後 Jwno が `set-focus-to-hwnd` を呼んだ |
| 別デスクトップから、Jwno が覚えているのと**別の**窓（C2）へ `SetForegroundWindow` | `focus-changed(C2)` が `virtual-desktop-changed` より先に届き、Jwno の `set-focus` の対象も C2 になった。**競合しなかった**（OS のフォーカスが先に着地し Jwno の「現在の窓」が C2 に更新されたため） |

## 緩和策の比較実験（run 4、`spike/run-experiment.ps1`、各条件 n=10、6 条件を交互に実行）
Core の `[:goto "1"]` + `[:focus C]` に相当する操作（デスクトップ 2 から 1 へ戻る `Win+Ctrl+Left` と
`SetForegroundWindow(C)`）の後、2 秒間 15ms 間隔でフォアグラウンドを観測した。Jwno が覚えている現在の窓は B。
「成功」= 2 秒後の前面が C。「戻された」= 一度 C が前面になった後で C でなくなった回数。

| 条件 | 成功 | C に着地するまでの中央値 | 戻された回数（計） | 再発行（計） |
|---|---|---|---|---|
| base（切替直後に `:focus`） | **0/10** | 3 ms | 8 | – |
| A（Jwno の `set-focus-to-hwnd` を握りつぶす） | **10/10** | 4 ms | 0 | – |
| B150（150ms 待ってから `:focus`） | 10/10 | 156 ms | 0 | – |
| B250 | 10/10 | 265 ms | 0 | – |
| B500 | 10/10 | 516 ms | 0 | – |
| C（即 `:focus`、250ms 後に不一致なら 1 回再発行） | 10/10 | 4 ms | 9 | 10 |

読み取れること（n=10・単一環境の範囲で）:
- base は、C が一瞬前面になった後に Jwno の再フォーカスで B に戻され、**毎回失敗**する（ちらつき + 誤った最終状態）。
- A はちらつきも失敗も無く最速。ただし Jwno の内部メソッドを差し替える結合が要る。
- B は 150ms でも 10/10 だったが、待っている間は Jwno が選んだ B が前面に見える。遅延は負荷に依存するため余裕を見る必要がある。
- C は最終的に必ず成功するが、**毎回 C→B→C と点滅する**（ユーザーに見える）。
- 限界: n=10、ホスト型ランナー（Windows Server 2022、モニタ 1 枚、窓 2 枚）のみ。負荷の高い実機での B の安全な遅延は未測定。
- 今回は、`set-focus-to-hwnd` 全般を握りつぶした。Jwno 自身のコマンド（`:focus` 系の組み込みコマンド）が
  使えなくなるかどうかは未検証。

## 解釈（推測を含む）
- Jwno は、レイアウトのあるデスクトップへ切り替わるたびに自分でフォーカスを動かす
  （`wm-desktop-name-changed` → `:set-focus`、`win.janet` で確認）。対象は Jwno が覚えている現在のウィンドウで、
  OS が選んだ前面と違うことがある。Core の `:goto` の直後の `:focus` は、**切替から約 100ms 以内だと Jwno に上書きされる**。
- 逆に、フォーカスの観測（`focus-changed`）が `virtual-desktop-changed` より先に届けば Jwno は Core と同じ窓を選ぶ。
  勝敗は到着順に依存する。これは ADR 0005 R1（`focus-changed` と `desktop-changed` の可換性）が必要な理由そのもの。
- `:focus` を別デスクトップの窓へ出すと、それが暗黙の `:goto` になる（ADR 0005 §4 の effect 順序の前提）。
- `:window-removed` が出ないのは、Jwno が `wm-focus-changed` の中で `clean-up-hwnds` を呼ぶ構造
  （`win.janet` で確認）のためで、フォーカス変化が無いと掃除されない、と見るのが自然。
  → ADR 0005 の `windows-observed` の定期／契機呼び出しが必要という前提を裏付ける。
- フォアグラウンドロックは**常にあるわけではない**。新しく作ったデスクトップ（前面のプロセスが無い）で出た。
  `:focus` が失敗しうる前提（ADR 0005 §1 観測原則）は妥当だが、頻度は実機で見る必要がある。
- デスクトップ 1 で `B` が前面を取り、デスクトップ 2 で取らなかった差の原因は未特定
  （プロセスの起動元、デスクトップの切替直後、など）。

## 未確認のまま
- 公開 COM による**他プロセスのウィンドウの移動**（`MoveWindowToDesktop`）。
- Jwno の自動 retile とウィンドウ位置の競合（ADR 0004 確認項目 2〜3）。
- Windows 10/11 のデスクトップでの挙動（DWM 枠の値、フォーカスロック、仮想デスクトップ API）。
- 実行順: run 2 から Jwno のシナリオを先に実行し、OS プローブ（デスクトップを作る）を後にした。
- **Core が出した `:place` を Jwno の `window :transform` 経由で適用するか、自前の `SetWindowPos` か**
  （`transform` は DWM の枠を補正する。ADR 0004 案 1/3 の判断材料）。
- 管理対象外ウィンドウの生成・消滅の通知源（ADR 0004 確認項目 1）。今回の窓はすべて Jwno が管理した。
- 確認項目 5 の**緩和策**の効果: Jwno の `:set-focus` を Shell が無効化/ラップする案（このスパイクで使った
  ラップと同じ手口）、`:goto` の後に `:focus` を遅らせる案（約 250ms 以上）、`:focus` 後の遅延再観測で不一致なら
  再度 `:focus` を出す案。どれも未検証。

## 契約テスト: xtile のアダプタを実際の Jwno 0.9.16 に載せた結果（run 5 の後。`spike/run-contract.ps1`）
ホスト型 Windows Server 2022、窓はメモ帳、モニタ 1 枚。**21 PASS / 0 FAIL / 4 INFO**。実機ではない。

| 確認 | 結果 |
|---|---|
| アダプタのロード | `--mod-path <repo>` と `(require "src/jwno/adapter")` で解決できた。相対 import（`../core/...`）も動く |
| id | Core の id は hwnd の10進数と一致。起動前からある窓も、`window-created` で Core に届く |
| `:place` | DWM の見える枠が Core の矩形と**完全一致**（3 枚とも diff 0）。読み戻しの不一致は 0 件 |
| `:swp-flags` による Jwno の無効化 | Jwno の `retile` が窓を動かさない。手動で動かした窓も retile では戻らず、Core の `:refresh` で戻る |
| 最大化 | **Jwno の retile は最大化を解除する**（`zoomed before=True after=False`。ソースの予測どおり） |
| ポーリング | 最小化した窓は 2 秒間隔の範囲内で Core から消え、復元で戻る |
| フォーカス | OS のフォーカスが同じ id で Core に届く。`focus-next` が実際のフォーカスを動かす（窓の `:set-focus` 経由で、抑止されない） |
| 仮想デスクトップ | 新デスクトップへの切替で Core の current が `"2"`、そこで開いた窓は tag `"2"`、戻ると `"1"`。往復で各窓の tag は保たれる |
| A（抑止） | デスクトップ切替で Jwno の `wm :set-focus` がちょうど 1 回だけ握りつぶされ、アダプタ自身の `:focus` に起因しない `leaf` の呼び出しは 0 回 |
| 自己診断 | 2 つのラッパーが入ったことを確認できた |

### 契約テストが見つけた不具合（すべて修正済み。フェイクのテストでは見つからなかった）
1. `jw32` に `GetClassName` / `GetWindowText` / `IsHungAppWindow` / `MessageBeep` が**ない**。未定義シンボルは Janet ではコンパイルエラーになる。
   class と title は `:window-created` の UIA 要素から取り、id ごとに覚える。
2. Jwno のキー名は小文字で、`Comma`/`Period` は `,`/`.`。Core の既定束縛をそのまま渡すと `install` 全体が止まった。
3. `GetWindow(GW_OWNER)` は「オーナー無し」で nil でなく **NULL ポインタ**を返す（Jwno は `null?` で判定）。nil 判定のままだと、すべての窓が
   「オーナー付き」= フロートになっていた（このとき CT-5 が空の PASS になっていた。以後、タイル窓が 0 枚なら FAIL にした）。
4. `GetWindowDesktopId` の結果は、Jwno 内では**整形済みの文字列**。GUID のバイト列として再整形すると別の ID になり、デスクトップが 2 つ以上になった途端に
   全窓が「対応できない」扱いでスナップショットから消えた。
5. `:window-created` は Jwno が窓を木に入れる**前**に発火し、フレームの無い窓は木に入らない。フックの後で `find-hwnd` が成功した窓だけを Core に渡す。
6. Janet の `band` は**符号付き 32 ビット**しか受け付けない。`WS_POPUP`（bit 31）のスタイルを符号なしにすると例外になり、その窓がポーリングから落ちた。
7. 契約テスト自身の誤り: デスクトップ切替の直後に新しい窓が現れて Core が正当にフォーカスを与えることがあり、「leaf の呼び出しは 0 回」という判定は
   厳しすぎた。アダプタ自身の `:focus` の分を引くようにした。

### 新たに分かったこと
- `jw32` に `SetWinEventHook` と `GetWindowLongPtr` がある。`window-moved`（ユーザーのドラッグ）や、通知の無い変化（最小化・フルスクリーン）を
  ポーリングに頼らず拾える可能性が出た（未実装）。
- 起動時、Jwno は実行環境自身のウィンドウ（`hosted-compute-agent` のコンソールなど）も管理する。

### まだ確認していない
- `:monitor-updated`（ディスプレイ設定の変更）後の再主張。ホスト型ランナーでは起こせなかった。
- 最大化した窓の扱いの可否（上記のとおり、retile で解除される。許容するかは設計判断）。
- UWP の窓での GA_ROOT と hwnd の一致、Windows 10/11 実機、複数モニタ、3 枚以上の窓、負荷のある状態。

## 契約テスト続き: `window-dragged`（`SetWinEventHook`）とポーリングの比較（ADR 0010 D9）
ホスト型 Windows Server 2022。メモ帳。`spike/run-contract.ps1` の CT-6〜CT-7、CT-17。

| 確認 | 結果 |
|---|---|
| `SetWinEventHook(MOVESIZEEND)` をメインスレッドで張り、ev ファイバーで `PeekMessage`/`DispatchMessage` を回す | **動いた**。ドラッグ後に `window-dragged id=… rect=…` が Core に届く。仮想デスクトップの往復の後でも生きている |
| ドラッグ 1 回につきイベントは | 1 回だけ（ドラッグ中には流れない） |
| タイトルバーを押して離しただけ | フロートにならない（`rect` が配置と同じなので、Core が何もしない） |
| ドラッグしたタイル | フロートになり、ドロップした位置にとどまる（2 秒後のポーリングの後も）。残りのタイルは詰め直される。`:toggle-float` でタイルに戻る |
| 最大化したタイル（ポーリングで検出） | フロートになり、最大化のまま残る。`:toggle-float` と復元で元のタイルに戻る |
| プログラムによる移動（`SetWindowPos`）後の Jwno の `retile` | マウスボタンを押している間はポーリングが比較しないので、窓は動かない。ボタンを離すと、次のポーリングで Core の矩形に戻される |

### 契約テストが見つけた、テスト自身の問題（アダプタの不具合ではない）
- `SetCursorPos` はカーソルを動かすだけで、移動ループが待つマウス移動入力を生成しない。ドラッグは絶対座標の `mouse_event` で行う。
  それでも窓の動きは意図した距離よりずっと小さい（`(−200, +160)` に対して `(−10, +8)` 程度）。ホスト型ランナーの入力の限界とみられる。判定は
  「動いた」と「そこにとどまる」にした。
- ホスト型ランナーでは `SetForegroundWindow` が拒否されることがある（前面ロック）。タイトルバーのクリックは確実に前面を与える。
- 最大化の検査で窓がフロートのまま次の検査に重なると、別の窓のタイトルバーを引いてしまう。使い捨ての窓で検査する。
- `CT-7a` は、前提（最大化の前にタイルであること）を確かめていなかったため、窓がすでにフロートなら空の PASS になっていた。前提の検査（`CT-7pre`）を足した。

### まだ確認していない
- キーボードによる移動（Alt+Space → M）、枠のドラッグによるリサイズ、Win+←/→ のスナップ、画面端へのドラッグスナップ。
- 管理外の窓のドラッグ（何も流れないこと）。
- 左右ボタン入れ替え設定、複数モニタ、実機の遅延・負荷。
- 50〜100ms のポンプ周期の CPU 負荷。

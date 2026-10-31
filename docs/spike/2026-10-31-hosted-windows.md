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

## 解釈（推測を含む）
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
- Jwno 自身の `:set-focus` / `:activate` と Core の `:focus` の競合（確認項目 5）。

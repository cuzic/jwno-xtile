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
| フォアグラウンドロック | **再現した**。デスクトップ 2 で、別プロセスから `SetForegroundWindow` が `False`、フォアグラウンドは動かなかった（デスクトップ 1 の一度目は成功） |
| `:window-removed` の取りこぼし | **再現した**。メモ帳 2 枚を `Stop-Process -Force` で終了し 3 秒待っても `:window-removed` が出なかった |

## 解釈（推測を含む）
- `:window-removed` が出ないのは、Jwno が `wm-focus-changed` の中で `clean-up-hwnds` を呼ぶ構造
  （`win.janet` で確認）のためで、フォーカス変化が無いと掃除されない、と見るのが自然。
  → ADR 0005 の `windows-observed` の定期／契機呼び出しが必要という前提を裏付ける。
- 新規ウィンドウがフォアグラウンドを取らない状況（デスクトップ 2）が実在する。Core が
  `:focus` を出しても効かない前提（ADR 0005 §1 観測原則）は妥当。
- デスクトップ 1 で `B` が前面を取り、デスクトップ 2 で取らなかった差の原因は未特定
  （プロセスの起動元、デスクトップの切替直後、など）。

## 未確認のまま
- `:focus-changed` が実際のフォーカス移動で発火する順序・重複排除（今回は起動時の 1 回のみ）。
- `:window-removed` が出る契機（フォーカス変化後に出るか）。
- 公開 COM による**他プロセスのウィンドウの移動**（`MoveWindowToDesktop`）。
- Jwno の自動 retile とウィンドウ位置の競合（ADR 0004 確認項目 2〜3）。
- Windows 10/11 のデスクトップでの挙動（DWM 枠の値、フォーカスロック、仮想デスクトップ API）。
- 実行順の副作用: `probe-os` が作ったデスクトップ 2 に Jwno の実行が引き継がれた。次回は切替を戻す。

# 0006. ワークスペースの実装方式とモニタモデル

- 状態: Proposed（未決。**state の形を変えるので ADR 0004 より先に決める**）
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

1. **仮想デスクトップ = ワークスペース**（jwno-layout-tall 方式）。OS の機能で他ワークスペースの
   ウィンドウが隠れる。VirtualDesktopAccessor に依存。モニタごとの独立切替は不可。
2. **自前の hide-show**（最小化／画面外退避）で、ワークスペースを Core のモデルだけで表現。
   OS 依存が最小。タスクバーやAlt-Tab との不整合、最小化アニメーション、アプリの復帰挙動が課題。
3. 案 1 の変種: **Jwno が持つデスクトップごとの Frame ツリーと検知機構を併用**する。
   デスクトップの切替・移動手段は提供しないため、単独では選択肢にならず、案 1 と組み合わせる要素。

併せて決める: タグを固定にするか動的にするか／モニタごとの現在ワークスペースを持つか。

## Decision

未決。スパイクで次を比較する: 案 1 の VirtualDesktopAccessor が対象 Windows ビルドで安定するか、
案 2 のウィンドウ復帰の挙動、案 3 が `:desktop-changed` 相当を与えるか。
決定までは Core の state を `:screen`（単一）と固定タグのままにし、複数モニタ対応を
始めない。

## Consequences

- 決定後、`state` の形（`:screens`, 動的タグ）と ADR 0001/0004/0005 を見直す可能性が高い。

## Confirmation

- 実機でのスパイク結果を追記し、選択肢ごとの落とし穴を記録して Accepted にする。

## スパイク記録（2026-10-31、ホスト型 Windows Server 2022。実機ではない）
詳細は `docs/spike/2026-10-31-hosted-windows.md`。
- 公開 COM `IVirtualDesktopManager` の `GetWindowDesktopId` / `IsWindowOnCurrentVirtualDesktop` は動いた。
- `Win+Ctrl+D` で仮想デスクトップを作成・切替でき、Jwno は `get-all-desktops` で 2 件を列挙した
  （レジストリ `VirtualDesktops` を読む実装）。窓には `desktop-info {:id :name}` が付く。
- **未確認**: 他プロセスのウィンドウを動かせるか（`MoveWindowToDesktop`）、`VirtualDesktopAccessor.dll` の
  動作、Windows 10/11 でのビルド依存。案 1 か 2 かの決定にはまだ足りない。

## ADR 0010 との関係（2026-10-31）
ADR 0010 の段階 1 は、仮想デスクトップの番号 → タグの**読み取り専用**の対応だけを先に入れる（観測側。`:goto`/`:send` は束縛しない）。
案 1（VD = ワークスペース）の読み取り側を先取りするもので、案 2（自前の hide/show）が選ばれたら作り直す。

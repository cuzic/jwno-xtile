# Architecture Decision Records

書式は MADR 4.0 を簡略化したもの。状態: Proposed → Accepted → Superseded。
新しい決定は番号を進めて追加し、覆す場合は旧 ADR を Superseded にして相互リンクする。

| # | タイトル | 状態 |
|---|---|---|
| [0001](0001-functional-core-imperative-shell.md) | FCIS を採用し、WM 状態の判断はすべて Core に置く | **Accepted** |
| [0002](0002-clean-room-mit.md) | MIT で公開し、GPL の jwno-layout-tall は参照のみ・独立再実装 | **Accepted** |
| [0003](0003-ai-assisted-development-workflow.md) | AI 支援開発のワークフローと検証の強制方法 | **Accepted** |
| [0004](0004-core-emits-rects.md) | Core は Frame 操作ではなく矩形を出力する | Proposed (要スパイク) |
| [0005](0005-effect-execution-and-drift-recovery.md) | 観測原則・effect の実行規約・ずれの回復 | **Accepted** |
| [0006](0006-workspace-and-monitor-model.md) | ワークスペースの実装方式とモニタモデル | Proposed (未決) |
| [0007](0007-xmonad-compatibility-scope.md) | xmonad 互換の範囲と管理対象ウィンドウ | **Accepted** |
| [0008](0008-window-classification-and-floating.md) | ウィンドウの振り分け（tile/float/ignore）とフロート管理 | **Accepted**（実装中） |
| [0009](0009-shell-runtime-and-port.md) | Shell は「ポート越しの実行系」と Jwno アダプタに分ける | **Accepted**（runtime と C は実装済み。緩和策 A+C は暫定。アダプタ未実装） |

レビュー履歴: 2026-10-31 Opus 1 回目（18 件）→ 反映。2 回目（R1〜R13, High 3）→ 反映。3 回目（S1〜S10, High 2）→ 反映。4 回目（T1〜T3）→ 反映。5 回目: 新規の High/Med なし、収束。
0001・0002・0005・0007 を Accepted に。0003 は Stop フック設定後に Accepted（2026-10-31）。0004（スパイク待ち）・0006（未決）は Proposed のまま。

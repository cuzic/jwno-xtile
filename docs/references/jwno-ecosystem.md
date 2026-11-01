<!-- Opus による調査（2026-11-01）。GPL・ライセンス不明のコードは読んでいない・取り込んでいない（ADR 0002）。 -->
<!-- 本プロジェクトの対応メモ: J4 の仮説（Name の照合失敗）は、実機の Jwno のログに "Virtual desktop name not found" が出ていなかったので、その run では支持されない。 -->
<!-- J3（transform が最大化を解除する）は park の hide/unpark にも当たる（Opus の実装後レビュー L2 と同じ）。 -->

# Jwno 周辺の既存実装の調査（jwno-xtile 向け）

調査日: 2026-11-01。方法: `gh search repos`、`gh api search/code`（GitHub のコード検索 API）、`gh issue`／GraphQL（Discussions）、WebSearch／WebFetch、MIT の Jwno 本体のローカル checkout（`~/jwno-xtile-ref/jwno`、`758edf38` = v0.9.16。upstream の最新リリースも v0.9.16（2025-12-22）で、その後のコミットは無い）。
GPL・ライセンス不明のリポジトリは、README、PR の説明文、コミットメッセージ、ファイル名、コメント行の要旨の確認にとどめた。クローンはしていない。コードは引用していない。

---

## (1) 要約

**Jwno の上でワークスペースや自動レイアウトを実装した公開物は、ほとんど無い。** 該当するのは 2 件だけ（lurdan/jwno-layout-tall＝GPL、BobTheHobo/jwno-config の `workspace.janet`＝ライセンス表示なし）。他に見つかった公開の `jwno-config.janet` は 3 件で、どれも `example-config.janet` 系の個人設定。独自レイアウトやワークスペースは実装していない。Janet の jpm／spork パッケージとして公開された Jwno 用ライブラリは**確認できず**。

参考にすべきもの（上位）:
1. **Jwno 本体（MIT）**: `auto-layout`（bsp／rows／close-empty-frame）、`scratch-pad`（`SW_HIDE` で隠し、仮想デスクトップをまたいで呼び戻す）、`layout-history`、`filter-window`／`filter-forced-window`／`:manage-window`。加えて、実機で見つかった問題の**原因がソースから読み取れる**（下の (4)）。コードの複製も可（NOTICE に著作権表示を足す）。
2. **Jwno の Issue／Discussions**: #29・#10（他プロセスの窓を公開 API で別のデスクトップへ移せない、作者も確認済み）、#14（起動時のフレームと複数モニタの既定の挙動）、#26・#34（作者の方針: Jwno は OS 標準のタスクバーや仮想デスクトップと組む。隠れた窓や独自のバーは本体に入れない）。ADR 0006 の判断の裏付けになる。
3. **BobTheHobo/jwno-config の README と設計コメント（ライセンス表示なし → 参照のみ）**: 「ワークスペース＝モニタの**代わりのトップフレーム**。モニタごと・仮想デスクトップごと」「`SW_HIDE` で隠す」「隠した窓に印を付けて、再起動後の Jwno が探して戻せるようにする」「`IsWindowVisible` を見る Jwno の生死判定を避ける」。jwno-xtile の park 方式と対照的な、もう一つの設計例。
4. **komorebi・GlazeWM の「隠し方」の設定項目（参照のみ）**: どちらも既定は cloak（非公開 API）。`SW_HIDE` は「Electron で問題」「レガシー」とされている。jwno-xtile の「既定は park、`SW_HIDE` は opt-in」の判断を補強する。
5. **VirtualDesktopAccessor は MIT**（`LICENSE.txt` で確認）。ADR 0002 の「ライセンス未確認」を更新できる（同梱する場合）。

取り込めないもの: **lurdan/jwno-layout-tall（GPL-3.0）**、**GlazeWM（GPL-3.0）**、**bug.n（GPL-3.0）**、**komorebi（Komorebi License 2.0。OSI のライセンスではない）**、**FancyWM（PolyForm Perimeter 1.0.1）**、**BobTheHobo/jwno-config ほか、ライセンス表示の無い設定リポジトリ**（既定で著作権者が全権利を持つ）。いずれも参照のみ。コードは取り込まない。

---

## (2) 発見したプロジェクト一覧

最終更新は GitHub API の `pushed_at`（2026-11-01 時点）。

| 名前 | URL | ライセンス | 最終更新 | 何を実装しているか | jwno-xtile との関係 |
|---|---|---|---|---|---|
| Jwno 本体 | https://github.com/agent-kilo/jwno | MIT | 2025-12-22（v0.9.16） | フレーム木の手動タイル。auto-layout（bsp／rows）、scratch-pad、layout-history、ui-hint、viewport（スクロール） | 土台。コードの参照・複製可（NOTICE に表示） |
| jwno-layout-tall | https://github.com/lurdan/jwno-layout-tall | **GPL-3.0** | 2026-10-27 | xmonad 風の Tall。ワークスペース 1〜9＝OS の仮想デスクトップ（VirtualDesktopAccessor） | **参照のみ。コードは取り込まない**（ADR 0002） |
| BobTheHobo/jwno-config（`workspace.janet`） | https://github.com/BobTheHobo/jwno-config | **不明（ライセンス表示なし）** | 2026-08-28 | i3／GlazeWM 風のワークスペース＋ワークスペースバー。モニタごと×仮想デスクトップごと。`SW_HIDE` で隠す。Jwno の本物の木をフェイク Win32 で動かすテスト | **参照のみ。コードは取り込まない**。設計の対照として有用 |
| steshaw/shelly | https://github.com/steshaw/shelly （`files/home/.config/jwno-config.janet`） | 不明（表示なし） | 2025-11-11 | example-config 系の個人設定（scratch-pad、layout-history、summon） | 参照のみ。独自レイアウト・ワークスペースは無い |
| TESTMECS/nixconfig | https://github.com/TESTMECS/nixconfig （`.config/jwno/jwno-config.janet`） | 不明（表示なし） | 2026-05-01 | 同上（layout-history、summon） | 参照のみ。関連は薄い |
| khoiw04/cinnamon-theme | https://github.com/khoiw04/cinnamon-theme （`Jwno/jwno-config.janet`、49 行） | 不明（表示なし） | 2026-05-26 | `filter-window` だけの小さな設定 | 関連は薄い |
| VirtualDesktopAccessor | https://github.com/Ciantic/VirtualDesktopAccessor | **MIT**（`LICENSE.txt`） | 2026-10-11 | 非公開 COM で仮想デスクトップを操作する DLL | ADR 0006 で不採用。ライセンスは MIT と確認できた |
| komorebi | https://github.com/LGUG2Z/komorebi | Komorebi License 2.0（非 OSI） | 2026-11-01 | 独自ワークスペースを持つタイル WM（Rust） | 参照のみ（設計の比較） |
| GlazeWM | https://github.com/glzr-io/glazewm | **GPL-3.0** | 2026-06-20 | i3 風のタイル WM | 参照のみ |
| Workspacer | https://github.com/workspacer/workspacer | MIT | 2025-06-15 | C# のタイル WM | 比較対象（深追いせず） |
| Whim | https://github.com/dalyIsaac/Whim | MIT | 2026-03-06 | モニタごとに独立したワークスペースを持つ動的 WM | 比較対象（深追いせず） |
| bug.n | https://github.com/fuhsjr00/bug.n | **GPL-3.0** | 2023-01-05 | AutoHotkey の dwm 風 WM | 参照のみ（深追いせず） |
| FancyWM | https://github.com/FancyWM/fancywm | PolyForm Perimeter 1.0.1 | 2026-09-21 | 動的タイル WM | 参照のみ（深追いせず） |
| yasb | https://github.com/amnweb/yasb | MIT | 2026-10-30 | ステータスバー（Jwno と組んだ例が Discussion #32 にある。設定は非公開） | 将来のバー連携の参考 |

検索で出なかったもの: Jwno 用の BSP 以外の独自レイアウト（spiral、centered master、wide 等）の公開実装、komorebi 風・xmonad 風の他の実装、Janet のパッケージ（jpm／spork）として公開された Jwno 拡張。GitHub のコード検索 API は既定ブランチのインデックスされたファイルしか見ないので、漏れはありうる。GitHub 以外（Codeberg、GitLab 等）は**確認できず**。

---

## (3) 各プロジェクトの設計の要点と、jwno-xtile への示唆

### 3.1 Jwno 本体（MIT）

- **ワークスペース**: 本体には概念が無い。作者は「Jwno は Windows の仮想デスクトップと組む」と明言している（Discussion #10: https://github.com/agent-kilo/jwno/discussions/10 ）。木は「仮想デスクトップのコンテナ → レイアウト（デスクトップごと。遅延生成）→ トップフレーム（モニタごと）→ フレーム → 窓」。デスクトップは**名前で識別**し、名前が重複すると挙動は未定義（`doc/content/ref/built-in-hooks/virtual-desktop-changed.mdz`）。
- **隠し方**: `scratch-pad` モジュールは `ShowWindow(SW_HIDE)` で隠し、`SW_SHOW` で戻す。別のデスクトップへ移った窓は「隠して→待って→見せる」をタイムアウトまで繰り返し、窓が現在のデスクトップに来るのを待つ（`src/scratch-pad.janet` の 100〜120 行付近）。Jwno は不可視の窓を木から外す（`wm-hwnd-alive?` は `IsWindow` と `IsWindowVisible` の両方を見る。`win.janet:3730`）。
- **フォーカス**: フォーカスの変化で、未管理の窓を**その場で**取り込む（`wm-focus-changed`、`win.janet:3471`）。`window-opened` でも取り込み、前面の窓ならアクティブにする（`win.janet:3550` 付近）。空のフレームにフォーカスするときは `set-focus-to-desktop`（`SHELLDLL_DefView` に UIA の `SetFocus`。`uia.janet:279`、`:50`）。
- **フロート・ルール**: `filter-window`（管理するか）、`filter-forced-window`（強制管理。`filter-window` より優先）、`:manage-window` コマンド。ドキュメントのクックブック: https://agent-kilo.github.io/jwno/cookbook/forcibly-manage-windows.html 、https://agent-kilo.github.io/jwno/ref/built-in-hooks/filter-window.html
- **レイアウト**: `auto-layout/bsp`・`rows`・`close-empty-frame`・`zoom-in`（https://agent-kilo.github.io/jwno/ref/built-in-modules/jwno--auto-layout.html ）。すべてフレームの分割として実装されている（Jwno の流儀）。v0.9.15 以降は viewport（`:toggle-parent-viewport`、`:scroll-parent`）でスクロール型レイアウトが作れる（Discussion #31: https://github.com/agent-kilo/jwno/discussions/31 ）。
- **永続化**: `layout-history` はフレームのレイアウトをファイルに保存して再起動後に戻せる（https://agent-kilo.github.io/jwno/ref/built-in-modules/jwno--layout-history.html ）。

jwno-xtile への示唆:
- **採る（済み）**: 矩形を Core が出し、Jwno のフレーム分割を使わない（ADR 0004）。auto-layout の「フレームを分割する」方式は、xmonad の StackSet と構造が合わない。
- **採る（検討）**: `layout-history` の考え方（状態をファイルに保存）は、ADR 0006 の「park した hwnd の永続化」や、再起動後に Core のワークスペースの割り当てを戻す機能に応用できる。Core の state は純データなので jdn に書き出せる。
- **注意**: Jwno の `scratch-pad` を jwno-xtile と併用すると、`SW_HIDE` された窓は Jwno の木から消え、jwno-xtile の `enumerate` からも消える。併用時の挙動は未検証。

### 3.2 lurdan/jwno-layout-tall（GPL-3.0。参照のみ。コードは取り込まない）

README は無い。以下は Discussion #37（https://github.com/agent-kilo/jwno/discussions/37 ）、PR #1 の説明文（https://github.com/lurdan/jwno-layout-tall/pull/1 ）、コミットメッセージによる。

- **ワークスペース**: 1〜9 を OS の仮想デスクトップに対応させる（VirtualDesktopAccessor.dll）。Windows 10 用ビルドには `CreateDesktop` が無いので、あるときだけ使う。
- **レイアウト**: Tall のみ。master は 1 枚固定。Jwno のフレームを Tall の形に組み直す。複数モニタは非対応。
- **既知の問題（作者の記述）**: 別ワークスペースへの移動でレイアウトが崩れることがある。ワークスペースの切替が時々おかしい。新しい窓が既存のフレームに入ることがある。
- **PR #1 で直したこと**: 窓を閉じたときにフレームが残る（Jwno の `:close` が兄弟のフレームを親に統合する）、別ワークスペースへの移動で元のフレームが残る、**Jwno の「現在のフレーム」が実際のフォーカスより遅れるので、OS の前面の窓（`GetForegroundWindow`）を優先する**、`:remove-hook` には「フック名」と「関数」の 2 つが要る、**起動時に既に開いている窓を Jwno に登録する**（一番手前の窓が master）。

jwno-xtile への示唆（アイデアのみ。表現は写さない）:
- 「起動時に既存の窓を取り込む」「OS の前面を Jwno の現在のフレームより信用する」は、jwno-xtile が実機で独立に見つけた問題（spike の 1、ADR 0005 の観測原則）と同じ。**互いに独立に同じ結論に達した**ことを ADR 0002 の独立性の記録に書ける（こちらは実機の契約テストで発見し、PR #1 を読んだのは今回の調査が初めて、という時系列の記録が要る。確認は lead に委ねる）。
- フレームを操作する方式の不具合（フレームが残る、統合の二重処理）は、jwno-xtile の「矩形を出す」方式（ADR 0004）では起きない。採らない判断の裏付けになる。

### 3.3 BobTheHobo/jwno-config `workspace.janet`（ライセンス不明。参照のみ。コードは取り込まない）

README と、ファイル冒頭の設計コメントの要旨（自分の言葉で要約）:
- **ワークスペースのモデル**: ワークスペースは「あるモニタの代わりのトップフレーム」。各モニタで 1 つだけがレイアウトにつながり、他は外して保持する。切替はトップフレームの差し替えなので、分割・比率・窓の積み重ねがそのまま保たれる。グループのキーは「レイアウト（＝仮想デスクトップ）×モニタのデバイス名」。**モニタごと・仮想デスクトップごと**にワークスペースを持ち、Jwno の仮想デスクトップ対応を置き換えずに組み合わせる。
- **隠し方**: `ShowWindow(SW_HIDE)`。戻すときは `SW_SHOWNA`（アクティブにしない）で見せ、最後に明示的にフォーカスする。万一のための `:show-all`。`:shutting-down` フックを使う。**隠した窓に印を付け、再起動した Jwno がそれを探して戻せるようにする**。
- **Jwno との相性の工夫**: Jwno の窓の `:alive?` は `IsWindowVisible` も見るので、隠したワークスペースが丸ごと purge される。だから生死は「窓が実際に破棄されたか」だけで判断する。外したフレームは Jwno が辿らないので、閉じた窓は自分で掃除する。隠している間は、迷ったフォーカスのイベントで木に引き戻されないよう Jwno に「触らない」と伝える。モニタの解像度・倍率の変化やモニタの抜き差しで、キーを付け替える。
- **テスト**: Jwno の本物のフレーム木のコードを、フェイクの Win32 層の上で動かす（jw32 不要、実窓に触れない）。

jwno-xtile への示唆:
- **採らない（確認）**: `SW_HIDE` を既定にすること。ADR 0006 の H1 の理由（クラッシュ時に窓が失われる、Jwno の木から外れる）が、このモジュールでも「印を付けて再起動時に戻す」「`alive?` を避ける」という追加の仕組みを必要にしている。park 方式はこれらが不要。
- **検討**: `SW_SHOWNA` で戻してから最後にフォーカスする順序は、ADR 0006 の `hide → show → place → focus` と同じ考え方。`:sw-hide` を opt-in で作るときは、上の「印を付けて永続化」「Jwno の生死判定を避ける」が必要条件になる（ADR 0006 の記述どおり）。
- **検討（将来）**: 「モニタごと×仮想デスクトップごと」のキーは、ADR 0006 D-4 で見送った「デスクトップごとに Core の state を持つ」設計の実例。需要が出たときの参考。
- **検討**: 「Jwno の本物の木をフェイク Win32 で動かすテスト」は、ADR 0010 のアダプタのテスト（フェイクの Jwno）より Jwno との結合部の再現度が高い。jw32 の stub を自作する必要があり、コストは大きい。

### 3.4 その他の公開設定（steshaw/shelly、TESTMECS/nixconfig、khoiw04/cinnamon-theme。ライセンス不明）

- キーワードの出現を数えただけ（中身は読んでいない）。example-config 系で、`scratch-pad`、`layout-history`、`:summon`、`auto-layout/close-empty-frame`、`filter-window`、`monitor-updated` を使う。ワークスペース・独自レイアウトは無い。
- 示唆: Jwno の利用者は「ワークスペースの代わりに `:summon`（アプリを呼び出すキー）と scratch-pad」を使う流儀が多い（Discussion #10 の利用者の結論とも一致）。jwno-xtile の利用者が Jwno の `:summon` を併用したとき、別のワークスペースにある窓を `:summon` すると park した窓にフォーカスが行く（ADR 0006 D-7 の (c) と同じ経路）。

---

## (4) Jwno 本体の既知の制限と回避策（本プロジェクトの実機の発見との対応）

| # | 制限 | 出典 | 本プロジェクトの発見・対応 |
|---|---|---|---|
| J1 | **他プロセスの窓を公開 API で別の仮想デスクトップへ移せない**。`IVirtualDesktopManager::MoveWindowToDesktop` は呼び出し側がその窓を持っているかを確かめて拒否する（作者の観察。公式ドキュメントには記載なし）。作者は非公開 API を「公式には」サポートしない方針。回避策として VirtualDesktopAccessor の FFI 利用例（#10）と、scratch-pad に入れてからデスクトップを切り替える方法（#29、一部の窓では効かない）が示されている | https://github.com/agent-kilo/jwno/discussions/29 、https://github.com/agent-kilo/jwno/discussions/10 | ADR 0006 の P1（`E_ACCESSDENIED`）と一致。ADR 0006 の Context の「出典は未整理」を、この Discussion で補える |
| J2 | **起動時に既存の窓を取り込まない**。フォーカスの変化（`wm-focus-changed`）か `window-opened` が来た窓だけを取り込む。起動時の走査は無い | ソース: `src/win.janet:3471`（`wm-focus-changed`）、`:3550` 付近（`wm-window-opened`）。Issue #14 で作者が「最初の管理可能な窓が現れたとき、全モニタのトップフレームを作る」と説明: https://github.com/agent-kilo/jwno/issues/14 | spike の 1 と一致。jwno-xtile の `adopt-existing!` と、jwno-layout-tall の PR #1 の「起動時の既存の窓のレイアウト」は同じ回避策 |
| J3 | **`transform` が最大化を解除する**。`transform-hwnd` は変形の前に UIA の WindowPattern で最大化を Normal に戻す（最小化は戻さず、その窓は変形しない）。ソースのコメントに「最大化した窓は見えているので戻す方が自然」とある意図的な挙動 | `src/win.janet:266` 付近（`transform-hwnd`）、`:143`（`reset-hwnd-visual-state`） | spike の 1 の副作用（「最大化した窓は Jwno の transform が解除する」）の原因。CT-7（最大化したタイルはフロートにする）で Core 側が先に分類するのは正しい。park（`:hide`）も `transform` で行うなら、最大化した窓を park すると**最大化が解除される**（戻したときに最大化に戻らない）。最大化した窓を park するときは `SetWindowPos` を直接使うか、`:show` で状態を戻す必要がある（unverified on Windows） |
| J4 | **`desktop-name-changed` が届かない／効かない**。Jwno は仮想デスクトップの切替を、UIA のルート要素の Name の変化イベントで検知する（`uia.janet` の `init-event-handlers`）。受け取った名前をレジストリ（`HKCU\...\Explorer\VirtualDesktops`）の一覧と突き合わせて GUID を得る。見つからなければ警告ログ「Virtual desktop name not found」を出して**何もしない**（`last-vd` も更新しない）。既定の名前は Windows がレジストリに書かないので、末尾の番号で照合する。名前が重複すると挙動は未定義 | ソース: `src/uia.janet:36`・`:471`、`src/win.janet:3574`（`wm-desktop-name-changed`）、`src/vd.janet` の `vdm-get-desktop-guid-from-name` と冒頭の Special Case のコメント。ドキュメント: `virtual-desktop-changed` フック https://agent-kilo.github.io/jwno/ref/built-in-hooks/virtual-desktop-changed.html | spike の 3 に対応。**仮説（未検証）**: 新しく作った直後のデスクトップは、レジストリの `VirtualDesktopIDs` がまだ更新されていない、あるいは名前と番号の照合に失敗し、イベントは来ているのに早期 return している可能性がある。**次の実機で、Jwno のログに「Virtual desktop name not found」「There is no virtual desktop with the index」が出ているかを確認する**とよい。どちらにしても、jwno-xtile がポーリング（`IsWindowOnCurrentVirtualDesktop`）で追従している設計は正しい。Jwno の `:virtual-desktop-changed` だけに頼らない |
| J5 | **`set-focus-to-desktop` はデスクトップのアイコンのリストビュー（`SHELLDLL_DefView`）に UIA でフォーカスする** | `src/uia.janet:279`、`:50`（`uia-manager-get-defview-window`）。scratch-pad もこれを使う（`src/scratch-pad.janet:390`） | ADR 0006 D-7b の「デスクトップのアイコンにフォーカスが行き、Enter／Delete／F2 が効く」という推論は、ソースで「フォーカス先が DefView」までは確認できた。キー入力の害は unverified on Windows のまま。sink 窓を採る判断を支持する |
| J6 | **不可視の窓は木から外れる**。`wm-hwnd-alive?` は `IsWindowVisible` を見る。`clean-up-hwnds` はフォーカスの変化ごとに走る。閉じかけの窓はすぐには purge されないことがある（ソースの XXX コメント） | `src/win.janet:3453`、`:3730` | ADR 0006 の「park は可視のままなので木に残る」の根拠。BobTheHobo の実装もこれを避ける工夫をしている（3.3） |
| J7 | **新しい窓は「現在のフレーム」に入る**。複数モニタでは、副モニタの窓がフォーカスされた途端に主モニタのフレームへ移る。回避策は `:window-created` フックで窓の `:frame` タグを、窓の中心を含むフレームに設定すること（作者のスニペット） | https://github.com/agent-kilo/jwno/issues/14 （OPEN） | spike の 1 の副作用「副モニタの窓も主モニタにタイルされる」と同じ。jwno-xtile は現在単一モニタ。複数モニタ対応の ADR を書くときは、Jwno がこの挙動で窓を動かす前に jwno-xtile が矩形を出すか、`:frame` タグで抑止するかを決める必要がある |
| J8 | **フロート（未管理）と最小化した窓は Jwno がほぼ無視する**。戻すための仕組みは無く、作者は scratch-pad を勧める | https://github.com/agent-kilo/jwno/issues/17 | ADR 0008 のフロート管理（Core がフロートを知っている）は、Jwno に無い機能を補っている |
| J9 | **同じフレーム内の窓はすべて可視である前提**。komorebi 風の「スタック（後ろの窓を隠す）」は対応しない方針 | https://github.com/agent-kilo/jwno/issues/26 | jwno-xtile の Full レイアウト（後ろの窓を隠すか）を設計するときに、Jwno の組み込みコマンドがこの前提を持つ点に注意 |
| J10 | 状態バーは本体に入れない方針。外部のバー（YASB）にソケットで状態を送る構成の例がある（設定は非公開） | https://github.com/agent-kilo/jwno/issues/34 、https://github.com/agent-kilo/jwno/discussions/32 | 将来のワークスペース表示は、Core の state を JSON で外へ流す形が Jwno の方針と合う |
| J11 | REPL のポート（127.0.0.1:9999）が他のツールと衝突しうる | 公開の Issue は**確認できず** | spike の経過の 1 回目。jwno-xtile 側で `-ReplPort` を足して回避済み |

`desktop-name-changed` が届かない、`transform` が最大化を解除する、`set-focus-to-desktop` の害、起動時の取り込みについて、Jwno の Issue／Discussion に**直接の報告は確認できず**（上の対応はソースから読み取ったもの。J2 のみ Issue #14 に間接の説明がある）。Jwno に報告する価値があるのは J4（新しいデスクトップでの検知漏れ。ログで原因を確かめてから）と J2（起動時の走査）。

---

## (5) 他の Windows タイル WM の設計比較（簡潔に）

| WM | ライセンス | ワークスペースの実体 | 隠し方 | 仮想デスクトップとの関係 | 出典 |
|---|---|---|---|---|---|
| komorebi | Komorebi License 2.0（参照のみ） | 独自のワークスペース（モニタごと） | `window_hiding_behaviour`: 既定 **Cloak**（「非公開の SetCloak 関数」）、Hide（`SW_HIDE`、**End of life。Electron アプリで問題**）、Minimize（頻繁な切替で問題） | 作者は「MS は仮想デスクトップとの統合を望んでおらず、リバースエンジニアリングした統合は Windows Update で壊れる」と述べる（Discussion #417）。v0.1.39 で仮想デスクトップの id を状態に記録する変更あり（詳細は確認できず） | https://lgug2z.github.io/komorebi/cli/window-hiding-behaviour.html 、https://komorebi.lgug2z.com/reference/komorebi-windows/ 、https://github.com/LGUG2Z/komorebi/discussions/417 |
| GlazeWM | GPL-3.0（参照のみ） | 独自のワークスペース（i3 風） | `general.hide_method`: v3.6.0 から既定 **cloak**、`hide` はレガシー（一部アプリで不安定）。cloak では全ワークスペースの窓がタスクバーに出る（`show_all_in_taskbar` で制御） | 独自（OS の仮想デスクトップは使わない。詳細は確認できず） | https://newreleases.io/project/github/glzr-io/glazewm/release/v3.6.0 |
| Whim | MIT | 独自のワークスペース。モニタごとに独立に活性化できる | README に記載なし（確認できず） | 「OS の仮想デスクトップはモニタごとに独立に切り替えられない」ので使わない | https://github.com/dalyIsaac/Whim/blob/main/README.md |
| Workspacer | MIT | 独自のワークスペース | 確認できず | 確認できず | https://workspacer.org |
| bug.n | GPL-3.0（参照のみ） | 独自の view（タグ） | 確認できず（深追いせず） | 確認できず | https://github.com/fuhsjr00/bug.n |
| BobTheHobo の workspace.janet | 不明（参照のみ） | モニタごと×仮想デスクトップごとの代替トップフレーム | `SW_HIDE`＋印で再起動時に回復 | Jwno の仮想デスクトップ対応と組み合わせる | 3.3 |
| jwno-layout-tall | GPL-3.0（参照のみ） | OS の仮想デスクトップそのもの | OS 任せ | 1 対 1（VirtualDesktopAccessor） | 3.2 |
| **jwno-xtile（ADR 0006）** | MIT | WM 内のグループ（単一モニタ） | **park**（-32000 へ移動、可視のまま）。`SW_HIDE` は opt-in（未実装） | 独立。現在のデスクトップの窓だけを扱う | — |

要点:
- **主要な WM（komorebi、GlazeWM）はどちらも cloak を既定にしている**。cloak は他プロセスの窓には公開 API で使えない（ADR 0006 P4 の `DWMWA_CLOAK` が `E_ACCESSDENIED`）ので、両者とも非公開 API に頼っていると読める（komorebi は「undocumented」と明記。GlazeWM の実装方法は確認できず）。jwno-xtile は非公開 API を避けるので cloak は採れない。park はその代替として妥当。
- **`SW_HIDE` は両者で「非推奨・レガシー」**。理由は Electron アプリとの相性・安定性。ADR 0006 で `SW_HIDE` を既定にしなかった判断を補強する（Electron の問題は、jwno-xtile が opt-in の `:sw-hide` を作るときの検証項目にする）。
- **cloak・park ではタスクバーに全ワークスペースの窓が残る**。GlazeWM はそれを設定で選ばせている。jwno-xtile の D-7（park した窓へのフォーカスを戻す／`:follow`）は、この共通の副作用への対処。komorebi・GlazeWM が「タスクバーで別ワークスペースの窓を選んだとき」にどうするかは**確認できず**（次の調査候補）。
- **仮想デスクトップは、どの WM も「使わない」か「最小限」**。理由は (a) 公開 API が足りない、(b) モニタごとに切り替えられない、(c) 非公開 API が Windows Update で壊れる。ADR 0006 の結論と一致。

---

## (6) 未確認・調査できなかった点

- GitHub 以外（Codeberg、GitLab、SourceHut、個人ブログ）の Jwno 設定・拡張は**確認できず**。WebSearch では OSNews の紹介記事と itch.io の devlog の題名しか出なかった。
- GitHub のコード検索 API はインデックスされた既定ブランチだけを対象にする。`jwno-config.janet` 以外の名前（例: `init.janet`、`config.janet`）の Jwno 設定は拾えていない可能性がある。
- jpm／spork のパッケージとしての Jwno 拡張は**確認できず**（検索で出なかった）。
- BobTheHobo の `workspace.janet` が、隠したワークスペースの窓へのフォーカス（タスクバー・Alt-Tab）をどう扱うかは、コード本体を読まない方針のため**確認できず**。README とコメント行の要旨のみ。
- komorebi・GlazeWM の、空のワークスペースへの切替時のフォーカスの扱い、タスクバーで他のワークスペースの窓を選んだときの挙動は**確認できず**。
- GlazeWM の cloak の実装方法（非公開 COM か）は**確認できず**（リリースノートに記載なし。GPL のソースは読まない）。
- Workspacer・bug.n・FancyWM の隠し方は**確認できず**（深追いしない指示に従った）。
- J4 の原因（新しいデスクトップでレジストリの照合に失敗している）は**仮説**。実機の Jwno のログで確かめていない。
- J3 の「park で最大化が解除される」は、ソースからの推論で **unverified on Windows**。
- lurdan/jwno-layout-tall の PR #1 が述べる「Jwno の現在のフレームが実際のフォーカスより遅れる」現象の再現条件（Firefox など）は、PR の記述以上は**確認できず**。
- VirtualDesktopAccessor は MIT と確認した（`LICENSE.txt`、rust ブランチ）。Windows 10 用の古いビルド（`2019-windows10`）のライセンスが同じかは**確認できず**。

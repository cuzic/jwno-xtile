# 0011. `:sw-hide`: ワークスペースを `SW_HIDE` で隠す opt-in モード

- 状態: Accepted（改訂 4、2026-11-02。Opus レビュー 3 回で収束。段階 0（park ＋ `DeleteTab`）は**実機で効くことを確認**（下の結果）。次は段階 0 の実装。`:sw-hide` 本体（段階 1）は、Alt-Tab からも消したい要望が出た場合に実装する）
- 日付: 2026-11-02

## Context

ADR 0006 は、他のワークスペースの窓を画面外 (-32000,-32000) へ移す `:park` を既定にした。`:park` の窓は可視のまま残るので、**タスクバーにも Alt-Tab にも出る**。
そこから選ぶと、画面外の窓にフォーカスが移る（D-7 の `:reclaim-focus` が約 0 ms で戻す）。ユーザーから見ると「別のワークスペースの窓がタスクバーに並んでいる」のは、
ワークスペースの感覚としては不自然で、xmonad／i3 のように「見えないものは見えない」にしたい人もいる。`SW_HIDE` はそれを実現する（komorebi／GlazeWM の `hide` 相当。ただし両者はこれを非推奨とし、
cloak を既定にしている。`docs/references/jwno-ecosystem.md`）。

ADR 0006 は `:sw-hide` を「将来の opt-in。採るなら、**終了時の全復元・隠した hwnd の永続化と起動時の回復・`window-removed` の抑止・再表示の確認を必須にする**」とした。この ADR はそれを決める。

**事実（ソースとスパイクによる。Windows 上の挙動は特記がない限り unverified）**:
- `SW_HIDE` した窓は、プロセスが生きていても、ユーザーが操作できない（タスクバー・Alt-Tab に出ない）。WM が落ちると**永久に失われる**。これが既定にしなかった理由。
- Jwno は不可視の窓を木から外す（`clean-up-hwnds`／`wm-hwnd-alive?` が `IsWindowVisible` を見る。フォーカスが変わるたびに走る）。`:window-removed` フックが発火し、`enumerate`（Jwno の木）に出なくなる。
  アダプタは今、`window-removed` を Core の `window-closed` に変え、`enumerate` の結果を `windows-observed` で Core に渡す（ghost の窓は Core から消える）。
- Jwno は、窓が再び現れる（UIA の `WindowOpened`、フォーカス）と、窓を木に入れ直す。`SW_SHOW` で確実に入り直すかは**未確認**。
- 既知の問題: Electron アプリで `SW_HIDE` が不安定（komorebi のドキュメント）。アプリが自分で再表示することがある。

## Decision

設定 `:hide-mode`（アダプタの opts。既定 `:park`、`:sw-hide` で本 ADR のモード）。Core は変わらない（`:hide`／`:show` の effect はそのまま。隠し方はアダプタの実装）。

### D-1 アダプタの内部状態: `sw-hidden`
`sw-hidden`: id → `{:hwnd :rect :zoomed :pid}`（隠した時点の見える枠、最大化していたか、プロセス ID）。`parked` と同様に OS 境界の記憶で、WM の判断ではない。`:hide`／`:show` ポートがこれを出し入れする。

### D-2 隠す（`:hide id`）と見せる（`:show id`）
- `:hide`: 窓を `hide` と同様に読み取り（枠・最大化）、`sw-hidden` に記録して**永続化**（D-4）してから `ShowWindow(SW_HIDE)`。最小化中の窓は `SW_HIDE` しない（`:park` の pending と同じ。復元後のポーリングで隠す）。
  結果を読み返す（`IsWindowVisible` が偽になったか）。偽にならなければ警告（再試行は `:park` の再 park と同じ上限）。
- `:show`: `ShowWindow(SW_SHOWNA)`（アクティブにしない）→ 記録した枠へ `transform-hwnd`（Jwno の木に依存しない）→ 最大化していたなら最大化し直す → **`(:window-opened wm hwnd)` で Jwno の木に入れ直す**
  （入っていなければ。`adopt-existing!` と同じ経路）→ 記録と永続化から外す。`:place`／`:focus` はこの後 Core が出す。

### D-3 Jwno の purge と `enumerate`（H の連鎖を防ぐ）
- `window-removed` フック: `sw-hidden` にある id なら **Core に流さない**（`window-closed` にしない）。`num->hwnd` と `extras` は消してよい。
- `enumerate`: Jwno の木の窓に加えて、`sw-hidden` の窓を **`[id nil facts]` として合成して含める**（facts は可視・非最小化の窓として。Core が `hidden?` で `drop-hidden` しないように）。
  これで `windows-observed` が隠した窓を ghost として消さない。窓が実際に消えた（`IsWindow` が偽）ものは合成せず、`window-closed` を流して記録を捨てる。
- ポーリング: `sw-hidden` の各窓を確かめる。(a) 生きていない → `window-closed` と記録の破棄。(b) アプリが自分で再表示した（`IsWindowVisible` が真）→ `:park` の再 park と同じ規則（上限つきで隠し直し、
  諦めたら `[:window-surfaced id]`、前面の窓は隠さない）。

### D-4 永続化と起動時の回復（クラッシュ対策）
- `sw-hidden` の記録を `%LOCALAPPDATA%\jwno-xtile\sw-hidden.jdn` に書く（隠す前に追記、見せたら更新。`parked` はメモリだけで足りるが、`SW_HIDE` は WM が落ちたら失われるので必須）。
  形式: `{:version 1 :windows [{:hwnd n :pid p :rect {...} :zoomed bool} ...]}`。書き込みは一時ファイルへ書いてから置き換える。
- 起動時（`recover-strays` の前）: 記録の各 hwnd について、`IsWindow` が真で、プロセス ID が一致し、`IsWindowVisible` が偽なら、`SW_SHOWNA` して記録した枠へ戻す（作業領域に収まらなければ収める）。
  戻したら記録を空にする。hwnd が再利用されて別のプロセスの窓だった場合は、プロセス ID の不一致で触らない。**記録が壊れていたら捨てる（窓には触らない）**。
- 正常終了（`:shutting-down`／`stop`）: 全ての `sw-hidden` を見せる（`restore-parked` の対応物）。強制終了（`taskkill`）では D-4 の起動時の回復だけが救う。ユーザー向けの手動回復手段として
  `jwno-xtile` の README にコマンドを書く（`(:xtile :show-all)` 相当）。

### D-5 フォーカスと最小化・仮想デスクトップ
- 隠した窓は OS のフォーカスを持てない。前面の窓を `SW_HIDE` すると Windows は Z 順の次の窓を前面にする。それが可視のワークスペースの窓でなければ（空のワークスペースなど）、
  `:stray-focus`／sink が従来どおり働く。
- `IsWindowOnCurrentVirtualDesktop` は不可視の窓でも答えるはず（未確認）。他の仮想デスクトップの窓は、従来どおり対象にしない。
- ワークスペースの割り当て（Core）は隠し方に依存しない。M4 の `:hidden-from` も同じ。

### D-6 採らない案
- cloak（`DWMWA_CLOAK`）: 他プロセスの窓には `E_ACCESSDENIED`（ADR 0006 P4）。
- 最小化で隠す: 復元時にアニメーション、Win+D との混同、最小化を Core が `drop-hidden` する（既存の意味と衝突）。
- `:sw-hide` を既定にする: ADR 0006 H1 の理由（失われる窓）が残る。永続化があっても、`taskkill`＋ファイル破損では失われうる。

### 不変条件・テスト
- **SW-1**（アダプタ側、P-1 の拡張）: タイマーを流し切った後、Core の可視ワークスペースの窓は画面上にあり（`IsWindowVisible` 真）、可視でないワークスペースの窓は `sw-hidden` にあり不可視か、最小化されている。
- **SW-2**: `sw-hidden` の窓は、Core に `window-closed` として流れない（生きている間）。`enumerate` は隠した窓を含む。
- **SW-3**: 正常終了のあと、`sw-hidden` は空で、全ての窓が可視。起動時の回復は、記録にある生きた不可視の窓を戻し、プロセス ID の不一致の窓には触らない。
- フェイク OS のプロパティテスト（P-1 と同じ形。ランダムな goto／send／close／最小化／復元／アプリ自身の再表示／再起動）に `:sw-hide` を加える。契約テスト（Windows）: `SW_HIDE` 後に `window-opened` で入り直るか、
  `IsWindowVisible`・タスクバーから消えるか、強制終了→再起動で戻るか。**すべて unverified on Windows**。

## Consequences
- 良い点: 他のワークスペースの窓がタスクバー・Alt-Tab から消える。`:park` の「そこから選ぶと戻される」摩擦が無くなる。
- 悪い点: 窓を失うリスク（永続化と回復で緩和するが、ゼロではない）、Electron などで不安定な可能性、Jwno の木との整合（purge と入り直し）の複雑さ。opt-in で、README に注意を書く。


## 改訂 2（2026-11-02。Opus レビュー A11-M1〜M6・L1〜L6 を反映。上の D-1〜D-6 と食い違う点はここが優先）

**前提の訂正: jw32 に無い API**（`jw32` の C ソースで確認）: `ShowWindowAsync`、`MoveFileEx`、`GetProcessTimes`、`OpenProcess`、`ITaskbarList`（`DeleteTab`／`AddTab`）。あるもの: `ShowWindow`、`SetProp`／`GetProp`／`RemoveProp`、
`GetWindowThreadProcessId`、`IsWindow`、`IsWindowVisible`、`SetWindowPos`、`PostMessage`／`SendMessage`、`CoCreateInstance`（COM のインタフェース定義は `IVirtualDesktopManager` だけ）。以下はこの範囲で決める。

- **段階 0（先にやる）: park ＋ `ITaskbarList::DeleteTab` のスパイク（Opus の推奨）**。動機が「タスクバーから消したい」だけなら、窓を可視のまま park し、タスクバーのボタンだけ消す案には、purge・入り直し・永続化・窓を失う経路がすべて無い。
  Alt-Tab からは消えない。jw32 に `ITaskbarList` が無いので、Janet の `ffi`（COM の vtable 経由）か jw32 への追加が要る。**この ADR の実装は、段階 0 の結果を見て範囲を決める**:
  `DeleteTab` が他プロセスの窓に効き、動機を満たすなら、`:sw-hide` は「Alt-Tab からも消したい」人向けの第 2 段として後回しにする。
- **A11-M1/M3 入り直しはポートの外で、表示中の記録を残す**: `:show` は `SW_SHOWNA`（同期の `ShowWindow`）と `transform-hwnd` だけを行い、**`window-opened` を呼ばない**。記録は `{:state :showing}` に変え、
  `enumerate` に合成し続ける。ポーリング（ポートの外、spawn した fiber）が、Jwno の木に入っていない `:showing` の窓に `(:window-opened wm hwnd)` を試み、入ったら（`find-hwnd` が真）最大化し直し、記録を消す。
  `:place`／`:focus` が木に無い窓に当たったら、`transform-hwnd`／`set-focus-to-hwnd`（木を引かない）で動く。SW-6: 入り直しが確認されるまで記録を残す。
- **A11-M2 `enumerate` の重複と仮想デスクトップ**: `sw-hidden`（`:hidden`／`:showing`）にある id は、Jwno の木側の項目を**捨て**、合成した項目だけを出す（SW-5: 同じ id を 1 回だけ、可視の facts で）。
  合成の facts は、保存した `extras`（class／title）を引き継ぐ（フロートのルールが効く）。合成は `on-current-desktop?` が真の窓に限る。隠した窓に対して答えない場合に備え、記録に隠した時点のデスクトップ ID を持つ（未確認）。
- **A11-M4 永続化**: 主手段を **`SetProp(hwnd, "jwno-xtile.hidden", rect の符号化)`** にする。印は窓に付くので、ファイルの破損・hwnd の再利用（新しい窓に印は無い）・別のマシンの記録に強い。
  起動時の回復は `EnumWindows` 相当（UIA の最上位の列挙。他のデスクトップの窓も含めて走査できるか未確認）で、印があり不可視の窓を戻して `RemoveProp` する。**補助として**ファイル
  `%LOCALAPPDATA%\jwno-xtile\sw-hidden-{a,b}.jdn` を世代つきの 2 ファイル（a／b を交互に書き、世代番号の大きい有効な方を読む。`MoveFileEx` が無いので置き換えはしない）。壊れた世代は捨てて古い世代を読む。
  両方壊れていたら窓には触らず、ログの error と起動時のツールチップで知らせる。プロセス ID に加えて印で照合する。**Jwno 無しの回復**: README に、印の付いた不可視の窓を戻す PowerShell を置く。
- **A11-M5 前面として再表示された窓**: `sw-hidden` の窓に `focus-changed` が来たら（前面になった）、ユーザーの意思とみなし、**`:reclaim-focus` より先に** `[:window-surfaced id]` を流す
  （アダプタが `focus-changed` を dispatch する前に判定）。前面にならずに再表示された窓だけを「アプリの再表示」として、`:park` の再 park と同じ上限で隠し直す。
- **A11-M6 応答しない窓と UWP**: `ShowWindowAsync` は無いので、`ShowWindow` の前に応答の確認（`hung?` が使えれば）を行い、応答しない窓は後回し（`later`）にする。**窓ごとに park へ戻す一覧**を持つ:
  既定は UWP（`ApplicationFrameWindow` のクラス。`extras` の class で判定）、ユーザーが exe／class を追加できる（`:sw-hide-exceptions`）。例外の窓は `:sw-hide` のモードでも `:park` で隠す。
- **L1** 終了時の全表示は `SW_SHOWNA`＋`transform-hwnd` だけ（`window-opened` は呼ばない。Jwno は `:shutting-down` の前に UI スレッドを止めるので、sink の破棄が失敗するのは無害）。
  **L2** `SW_HIDE`／`SW_SHOWNA` のたびにタスクバーのボタンの並びが変わりうる（Consequences に書く）。**L3** Jwno は単一インスタンス（`check-single-instance`）なので記録の取り合いは無い。
  **L4** 隠した窓を表示したときに現れる仮想デスクトップ（隠したときか、現在か）は未確認。契約テストに入れる。**L5** owned 窓は所有者が隠れても残る（`:park` と同じ。所有者がタスクバーに無いので分かりにくい）。
  **L6** テスト: クラッシュの注入（印の付与前後・`SW_HIDE` の前後・`:show` の各段階）、Jwno の purge の遅れと UIA の遅れをフェイクに入れる、SW-4（先行書き込み: 不可視にした窓の集合 ⊆ 印とファイル）・SW-5・SW-6、
  park モードの既存テストが `:hide-mode` 既定のまま全て通ること。


## 改訂 3（2026-11-02。Opus 2 回目の確認 A11b-H1・M1・M2・L1〜L5 を反映。改訂 2 までと食い違う点はここが優先）
- **A11b-H1 起動時の回復の列挙は UIA ではなく `GetWindow` の走査**: UIA は `SW_HIDE` した不可視の窓を木に出さない（推論）ので、印があっても見つけられない。回復は
  `GetWindow(GetDesktopWindow(), GW_CHILD)` から `GW_HWNDNEXT` で最上位の窓を**全部**辿り（不可視も含む）、`GetProp(hwnd, "jwno-xtile.hidden")` が付いた窓を戻す。jw32 に `GetDesktopWindow` が無ければ
  `GetWindow(hwnd, GW_HWNDFIRST)` を使う手がある（`FindWindowEx(nil, nil, nil, nil)` の繰り返しでも辿れる）。`GetProp`／`RemoveProp`／`GetWindow` は jw32 にある。
  **これを段階 1（`:sw-hide`）の最初の契約テストにする**: 窓に印を付けて `SW_HIDE` し、`GetWindow` の走査で見つかるか。
- **A11b-M2 隠す・見せるは `SetWindowPos` の非同期**: `IsHungAppWindow` は jw32 に無く `hung?` は常に偽なので、応答の確認は当てにならない。`ShowWindow` の代わりに
  `SetWindowPos(hwnd, nil, 0, 0, 0, 0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_ASYNCWINDOWPOS|SWP_HIDEWINDOW)` で隠し、`...|SWP_SHOWWINDOW` で見せる
  （`SWP_ASYNCWINDOWPOS` は他スレッドの窓でも呼び出し側をブロックしない）。結果の読み返し（`IsWindowVisible`）は次のポーリングで行う。`:show` の枠の復元は `transform-hwnd`（これも他スレッドの窓に同期でメッセージを送る点は `:park` と同じ）。
- **A11b-M1 段階 0 のスパイクの確認項目**（park ＋ `DeleteTab`）: (1) 他プロセスの窓のタスクバーのボタンが消えるか、(2) アクティブ化・タイトルの変更・`FlashWindow`・`SetWindowPos` の後も消えたままか、
  (3) Explorer の再起動（`TaskbarCreated`）の後、(4) 仮想デスクトップの往復の後、(5) Windows 11 の新しいタスクバーで効くか。持続しない場合は、ポーリングごとに `DeleteTab` をやり直す（安価）か、
  段階 0 は動機を満たさないと判断する。Explorer の再起動には、Jwno の UI スレッドが処理する `TaskbarCreated` から main へ通知して、park 中の窓すべてに `DeleteTab` をやり直す経路を設計する。
  ffi は、`ole32.dll` の `CoCreateInstance` を直接呼び、返った COM ポインタの vtable を `ffi/read` で読んで `HrInit`(3)・`AddTab`(4)・`DeleteTab`(5) を `ffi/call` で呼ぶ。COM は main スレッドで。誤ると Jwno が落ちるが、
  park の窓は `recover-strays` で戻るので失われない。スパイクの前提: jwno.exe に ffi があるか（CI の `contract.log` の `ffi-has` 行で確認する。run 41407319883）。
- **L1 `SetProp` の細部**: 印の付与に失敗したら**隠さない**（SW-4 の先行書き込みの一部）。データは `HANDLE`（ポインタ幅）なので、rect は 4×16 ビット（符号つき）に詰めるか、収まらなければ印は「隠した」だけとして rect はファイルに頼る。
  jw32 の `SetProp` が整数を受けるか確かめる。プロパティ名の atom は 1 つ。窓の破棄でプロパティはシステムが片付ける。
- **L2** `:showing` の入り直しの試行に上限（N 回）。超えたら記録を消し、合成をやめる（Core には、ghost として消えるに任せる）。**L3** 試行は `:showing` になってから 1 秒以上たった窓だけ（Jwno 自身の取り込みとの二重を避ける）。
- **L4** `window-removed` で `extras` を消さない（`:hide` の時点で `extras` を記録に写す）。D-3 の該当の文言は改訂 2 で上書きされる。
- **L5** ファイルは 1 世代遅れうる（書きかけで落ちた世代は捨てて前の世代を読む）。**印が正、ファイルは補助**（rect の復元用）と明記する。


## 改訂 4（2026-11-02。Opus 3 回目の確認 A11c-M1・L1〜L4 を反映。収束）
- **A11c-M1 「見せる」は同期に戻す**: 非同期にするのは**隠すとき**だけ（`SWP_ASYNCWINDOWPOS|SWP_HIDEWINDOW`）。「見せる」は、直後の `transform-hwnd`・`:place`・`:focus` が不可視の窓に当たって 1 往復遅れるのを避けるため、
  `SetWindowPos(... SWP_SHOWWINDOW|SWP_NOACTIVATE)` を**同期**で呼ぶ。同期の呼び出しが応答しない窓で止まる危険は受け入れる（`:park` の `transform` と同じ性質。窓ごとの park への戻しの一覧で緩和する）。
- **L1** `GetWindow` の走査には回数の上限（例: 100 000）と再訪の検出（同じ hwnd が二度出たら中断）を付ける。**L2** `SWP_HIDEWINDOW` でタスクバーのボタンが消え、見せると戻るかを契約テストに足す。
- **L3 印の外し忘れを防ぐ**: 印（`SetProp`）は、(a) `:show` で表示したとき、(b) `[:window-surfaced id]` のとき、(c) 前面で再表示されたとき、(d) 起動時の走査で可視だったとき、のいずれでも `RemoveProp` する。
  外し忘れると、ユーザーがトレイに閉じた不可視の窓を次の起動で勝手に出す。起動時の回復は「印があり、不可視で、記録の PID と一致する窓」だけを戻す。
- **L4** 同期の `show` が応答しない窓で止まる危険を受け入れる旨は上記のとおり。

## 段階 0 のスパイクの結果（2026-11-02、ホスト型 Windows Server 2022、run 41409792021）
- Janet の FFI は jwno.exe に入っている（`ffi/native`・`ffi/call` が使える）。`CoCreateInstance(CLSID_TaskbarList)` → `HrInit` → `DeleteTab`／`AddTab` を **FFI の vtable 呼び出しで実行でき、いずれも `S_OK`**。Jwno は落ちなかった
  （`spike/taskbar-config.janet`）。jw32 に `ITaskbarList` が無くても実装できる。
- **タスクバーのボタンが実際に消えたかは、ホスト CI では観測できなかった**（UI Automation でタスクバーのボタンを数えても常に 0 件）。効果（他プロセスの窓に効くか、アクティブ化・タイトル変更・点滅・Explorer の再起動・
  仮想デスクトップの往復の後も消えたままか、Windows 11 のタスクバーで効くか）は**実機で確かめる**（`spike/run-taskbar.ps1` を実機用に使える）。
- **実機（Windows 11）での段階 0（2026-11-02）**: FFI 経由の `DeleteTab`／`AddTab` は実機でも `S_OK`（新しい仮想デスクトップの中で、スクリプト自身が作った専用の窓に対して。ユーザーの窓は変化なし）。
  ただし**ボタンが消えたかは自動では測れなかった**（Windows 11 のタスクバーの UI Automation は、基準の時点でもテスト窓のボタンを返さなかった）。`spike/real/taskbar-manual.ps1`（目で確認する手動スクリプト。Jwno を使わない）を用意した。
  その結果（ボタンが消えるか、アクティブ化・タイトル変更・点滅の後も消えたままか、`AddTab` で戻るか）を得てから、段階 0 の採否を決める。

- **段階 0 の実機の結果（2026-11-02、Windows 11、スクリーンショットで確認）**: スクリプト自身が作った専用の窓（コンソールを持たないホスト）に対して、FFI 経由の `DeleteTab` は**タスクバーのボタンを消した**。
  アクティブ化・タイトル変更・点滅の後も**消えたまま**。`AddTab` で**戻った**。窓を閉じるとボタンの残骸は無い。ユーザーの窓は変化なし。測定は、ホストを Hidden で起動すると最初の窓が隠れる点と、
  同じプロセスのコンソール窓が同じタスクバーのグループに残る点で、数回やり直した（`spike/run-taskbar.ps1`、`spike/real/`）。
  **未確認**: Explorer の再起動（`TaskbarCreated`）の後、仮想デスクトップの往復の後、複数モニタ、Alt-Tab には影響しないこと（想定どおり残る）。ホスト CI では UI Automation が効果を観測できない。
- **決定（段階 0 の実装）**: opts `:hide-taskbar-button` を足す（既定は偽）。真のとき、`:hide`（park）の窓に `DeleteTab`、`:show`／`unpark`／終了時の復元に `AddTab` を呼ぶ。FFI（`CoCreateInstance` → vtable の `HrInit`(3)・`AddTab`(4)・`DeleteTab`(5)）は
  `win32.janet` に置き、失敗しても park は続ける（ボタンが残るだけ）。Explorer の再起動への対応（`TaskbarCreated` で消し直す）は、まずポーリングごとに park 中の窓へ `DeleteTab` を呼び直す安価な形にする。

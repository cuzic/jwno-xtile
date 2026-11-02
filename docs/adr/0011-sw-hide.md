# 0011. `:sw-hide`: ワークスペースを `SW_HIDE` で隠す opt-in モード

- 状態: Proposed（2026-11-02。Opus レビュー待ち。実機は未検証）
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

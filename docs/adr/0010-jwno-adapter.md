# 0010. Jwno アダプタ: ポートの実装、フック→event の変換、Jwno との分担

- 状態: Accepted（改訂 4: Opus レビュー 3 回で収束、2026-10-31。実装は未了。API はソースを読んだだけで Windows 未検証。ADR 0004 は契約テストまで Proposed）
- 日付: 2026-10-31

## Context

ADR 0009 は runtime とポート `ctx` を定めたが、ポートを Jwno の上に実装する層（アダプタ）は未着手。
ADR 0004（Core は矩形を出す。Jwno の Frame ツリーとどう橋渡しするか）は未決のままである。この ADR は
アダプタの構造、ポートと Jwno の API の対応、Jwno のフックから Core の event への変換、Jwno との役割分担を決める。

**Jwno のソース（`~/jwno-xtile-ref/jwno/src/win.janet`, 0.9.16）とスパイク（`docs/spike/`）で確認した事実**:
- 管理対象にした窓は、`:window-created` フックの**後**に必ず Frame へ追加され `:transform` で配置される
  （`wm-add-hwnd`）。フックは Jwno の処理の**途中**で同期的に呼ばれ、戻った後に Jwno 自身が transform／retile／
  `:set-focus` を行う（`handle-display-changed` も `:monitor-updated` → `retile` → `:set-focus`）。起動時にも既存の窓に対して発火する。
- `transform-hwnd` は窓の tags の **`:swp-flags` を `SetWindowPos` にそのまま OR する**。`window-transform` は
  `(merge (in win :tags) call-tags)` で**呼び出し側が後勝ち**。`SWP_NOMOVE|SWP_NOSIZE` を立てれば Jwno の配置は位置もサイズも
  変えない。ただし最大化の解除（`reset-hwnd-visual-state`）は先に走り、最小化中の窓は黙って飛ばす。例外は内部で握りつぶす。
- `transform` に渡す矩形は**見える枠**（DWM の枠を除く）。右下は排他的（`:left :top :right :bottom`）。
- `window :transform` は DWM の見えない枠を補正して置く（スパイクで実測）。`retile` は全窓を Frame に戻す。
- `:window-removed` は、強制終了した窓についてフォーカス変化が起きるまで遅れる。最小化・フルスクリーン・
  タイトル変更を知らせるフックは無い。Jwno は `SetWinEventHook` を使っていない（UIA ベース）。
- `wm-desktop-name-changed` は `:virtual-desktop-changed` フックを同期で呼んだ直後に `(:set-focus self lo)` を呼ぶ（ADR 0009 A）。
- 管理ウィンドウを前面から順に返す `tree-node-get-window-stack`（`EnumChildWindows(nil)` の z 順）がある。
- 設定ファイルと同じディレクトリのモジュールを `(import name)` で読める（`--mod-path` で追加可）。

## Considered Options

1. **Jwno を観測と配置の道具に限り、Jwno 自身の配置を `:swp-flags` で無効化する**。Core の矩形は `window :transform` で適用する。
2. 配置の無効化をせず、アダプタが Jwno の後追いで置き直す（再主張・復元）。→ Jwno はフックの後で必ず上書きする（レビュー H1）。
3. Jwno を使わず自前の WinEvent と `SetWindowPos` で書く。→ UIA・仮想デスクトップ列挙・DWM 補正を捨てる。作る量が大きく、`SetWinEventHook` の有無が未確認。
4. Core の矩形を Jwno の Frame ツリーに反映する（ADR 0004 案 2）。→ effect の語彙が変わる（ADR 0001 の改訂が要る）。

## Decision

案 1。**ADR 0004 の案 1（Shell が矩形を直接適用）の変種**であり、同 ADR が挙げた反論「Jwno に管理させれば二重配置・retile での
上書きが起きる」に対する答えが `:swp-flags` による Jwno の配置の無効化である。ADR 0004 は Proposed のまま、本 ADR を
「条件付きで採る」位置づけにし、条件は契約テスト（下記）で二重配置・retile・最大化を確かめること。ADR 0004 側にも追記する。

### D1 構造（依存注入。ADR 0001）
- `src/jwno/adapter.janet`: `(install context win32 opts)`。**`jw32` も `jwno/*` も import しない**。`jwno/context` と OS 呼び出しを束ねた
  `win32` テーブルを引数で受ける（Linux でフェイクを渡してロード・テストできる）。
- `src/jwno/win32.janet`: `jw32` を import する唯一のファイル（`GetForegroundWindow`、`GetAncestor`、スタイル・矩形の取得、`SWP_*` 定数など）。
  Windows でだけロードする。
- `jwno-config.example.janet`（リポジトリ直下）: 両者を import して `install` を呼ぶ。Jwno の Frame 系キーは束縛しない。

### D2 役割分担
Core が配置とフォーカスの唯一の権威。Jwno は (a) 窓の生成・消滅・フォーカスの観測源、(b) 配置の道具、(c) 仮想デスクトップ情報の源に限る。
`:window-created` で窓の tags に `:swp-flags = SWP_NOMOVE|SWP_NOSIZE` を立てる。これにより Jwno の初回配置・`retile`・最小化からの復元時の
`transform` は位置もサイズも変えない（二重配置・点滅・フロートの復元が不要になる）。アダプタの `:place` だけが
`(:transform win rect @{:swp-flags 0} wm)` で実際に動かす。Jwno の `:monitor-updated` は `[:screen-changed work-area]` と
`[:command :refresh]` に変えて Core に再主張させる（Jwno の retile は動かさないので、競合しない）。

### D3 フックの中では dispatch しない（レビュー H1）
Jwno のフックは Jwno の処理の途中で同期的に呼ばれ、戻った後に Jwno が `:set-focus` などを行う。そのためアダプタは、フックの中で
**値だけを取り出し**（hwnd、facts、desktop-info など）、`(ev/spawn (rt/dispatch ...))` で Jwno の処理が戻った後に流す。
フックごとの「戻った後に Jwno が行うこと」: `window-created` → `add-child` + `transform`（D2 で無害化）／`monitor-updated`
（`handle-display-changed`）→ `retile` + `(:set-focus wm cur-frame)`／`virtual-desktop-changed`（`wm-desktop-name-changed`）→ `:set-focus`
（D7）／`focus-changed` → 未管理窓なら `filter-window` と `add-hwnd`、管理窓なら `:activate`。

**id の規約（レビュー M-A）**: Core に入る id はすべて `pointer-to-number` した整数。Jwno の hwnd は pointer 型で、Core の `valid-id?` は
pointer を受け付けず**黙って無視する**ため、変換を 1 つの関数 `(norm hwnd)` にまとめ、フックの hwnd・snapshot・`window-closed`・`:foreground` の
**すべての流入口で同じ関数**を通す（`GetAncestor(GA_ROOT)` への正規化もここで行う。規則が流入口ごとにずれると幽霊が生まれる）。ポートで
受け取る数値 id は、アダプタが持つ「数値 → pointer」の表で戻す。表は `window-created` で追加、`window-removed` で削除、**snapshot で置き換える**（`window-removed` が来ない窓の項目を溜めない）。`norm` は NULL（死んだ hwnd への `GetAncestor` の結果など）を **nil にする**（`pointer-to-number` で 0 になり Core の有効な id になってしまうため）。`window-removed` の前に HWND が再利用されると、Jwno は古い窓オブジェクトを「管理中」として扱い `window-created` が来ない（まれ。許容し、契約テストの注意事項にする）。フェイクのテストでは
hwnd を pointer 風の非数値にして、変換の漏れを検出する。

### D4 ポート ↔ Jwno（`wm = (in context :window-manager)`。名前・引数はソースで確認、**実機未検証**）
| ポート | 実装 |
|---|---|
| `:place id rect` | id を pointer に戻して `(:find-hwnd wm hwnd)` → 窓。`{:x :y :w :h}` を `{:left x :top y :right (+ x w) :bottom (+ y h)}` に変換し `(:transform win rect @{:swp-flags 0} wm)`。**窓が無いときだけ投げる**（幽霊）。`transform` は内部で例外を握りつぶすので、直後に `(:get-rect win true)`（見える枠）を読み、**目標と違えば投げずに `[:window-moved id 実際の矩形]` を spawn で dispatch する**（`place` と同じ座標系。Core の既存の `:misfit` が 3 回まで再配置して諦める。ADR 0005 §2。許容値は契約テストで実測して決める。暫定は一致のみ）。最小化中（Jwno が黙って飛ばす）とハング中（`IsHungAppWindow`）の窓は比較しない |
| `:focus id` | 窓の `(:set-focus win wm)`（`wm` の `:set-focus` ではない。ADR 0009 A-2）。UIA の `SetFocus` は失敗を返さないので、成否は R-4 の再観測と R-10 に任せる |
| `:close id` | `(:close win)`（`WM_CLOSE` 投函） |
| `:foreground` | `GetForegroundWindow` を `GetAncestor(GA_ROOT)` に（所有者へは寄せない。ADR 0009 H1） |
| `:foreground-is? id` | `:foreground` との完全一致 |
| `:enumerate` | `(:get-window-stack (in wm :root))`（z 順。**全仮想デスクトップ**の管理窓）。各窓に facts（D6）と tag（D8）を付ける。窓ごとに `protect` し、失敗した窓は除く。**Jwno の vd-manager 経由の問い合わせ（チャネルで yield し、失敗時は約 1.5 秒リトライする）はポートとフックの中で使わない**。デスクトップは `win32` の `IVirtualDesktopManager`（同期・リトライなし）か、フックの引数 `desktop-info` と Jwno のキャッシュで引く |
| `:work-area` | `:monitor-updated` の引数 `top-frame` の主モニタ（`:flags`）の作業領域。起動時は `(:enumerate-monitors wm)` の `main-idx` |
| `:later d thunk` | `(ev/spawn (ev/sleep d) (thunk))`（Jwno のイベントループ上。`dispatch` と同じスレッド） |
| `:log` / `:notify` | `jwno/log`／`MessageBeep` |
| `:goto` / `:send` | 段階 1 では束縛しないので Core は出さない。到達したら普通に投げる（バグの検出） |
| `:current-desktop` | Jwno の `last-vd`（wm 生成時に現在の VD で初期化され、`wm-desktop-name-changed` が更新）を D8 の規則で tag に引く。引けなければ nil（R-8 は省く） |

### D5 フック → event（すべて D3 の spawn 経由）
| Jwno のフック | Core の event |
|---|---|
| `:filter-window` | **使わない**（Jwno の既定フィルタに任せる。分類は Core の `window-seen` に一本化する。レビュー M3） |
| `:window-created`（`win uia-win exe-path desktop-info`） | tags に `:swp-flags` を立て（D2。フック内で同期）、`[:window-seen (norm hwnd) facts tag]` を spawn。tag は `desktop-info` の `:id` から（D8）。フックの中で vd-manager を呼ばない |
| `:window-removed`（`win`） | `[:window-closed (norm hwnd)]` |
| `:focus-changed`（`hwnd`、nil あり） | `[:focus-changed (norm hwnd)]`（nil はそのまま。`:foreground` と同じ規則。レビュー M4） |
| `:virtual-desktop-changed`（`guid name layout`） | `[:desktop-changed tag]`（guid → tag。D8）。A の抑止は D7（`:desktop-name-changed` のラップ側で行う。このフックでは何もしない） |
| `:monitor-updated`（`top-frame`） | `[:screen-changed work-area]` → `[:command :refresh]` |
| `:window-activated` / `:frame-*` / `:layout-*` | 無視 |
| 定期スナップショット（`:poll-seconds`、既定 2） | `[:windows-observed (enumerate)]`（毎回、全管理窓に `:swp-flags` が立っていることも確かめて立て直す。レビュー L2） |

定期スナップショットは、通知源が無い変化（最小化・復帰・フルスクリーン・タイトル・遅延した `window-removed`）を `facts` の差として伝える唯一の
手段（ADR 0008 の hidden 判定）。遅延は最大でポーリング間隔で、その間、復帰した窓は Core の管理外（`:close` が効かない）。復帰は
snapshot の `append` で入るので、ADR 0008 の「insertUp で新規扱い」とは位置の扱いが違う（ADR 0007 の互換表に差異として追記する）。
**ユーザーのドラッグによる** `window-moved` は、`SetWinEventHook` の有無が分かるまで流さない（`:place` の読み戻しの不一致は D4 で流す）。

### D6 facts（`classify` の facts と同じスキーマ。ADR 0008）
`win32.janet` が Win32 から取る（UIA は呼ばない。ポーリングごとに窓数ぶん呼ぶため）: `:class`、`:exe`、`:title`、`:visible?`、
`:minimized?`（`IsIconic`）、`:fullscreen?`（アプリが要求したフルスクリーンに限る＝矩形がモニタ全体で `WS_CAPTION` 無し。Core 自身が置いた
タイルと区別する）、`:dialog?`、`:tool-window?`（`WS_EX_TOOLWINDOW`）、`:owned?`（`GW_OWNER`）。

### D7 A（ADR 0009 A-1〜A-4）の実装 — メソッド単位のラップ（レビュー M2）
時間に依存する単発フラグはやめ、制御フローで範囲を決める。`wm` インスタンスの **`:desktop-name-changed`** をラップし、
`(defer (set suppress false) (set suppress true) (orig self name))` の間だけ、`wm` の **`:set-focus`** のラッパーが呼び出しを捨てる。
`:desktop-name-changed` は `main.janet` のイベントループからメソッドとして呼ばれる（`(:desktop-name-changed wm vd-name)`）。
`:virtual-desktop-changed` フック（同期）は元のメソッド内で呼ばれる。この間に呼ばれる `wm :set-focus` が Jwno 内でその 1 か所だけである
ことは契約テストで確認する。アダプタの `:focus` は窓の `:set-focus` を使うので影響を受けない（A-2）。
起動時の自己診断: **`:set-focus` と `:desktop-name-changed` の両方**のラッパーが入ったこと（`(= (in wm :set-focus) wrapper)` など）と、Jwno の版が固定リストにあること。抑止中に他のファイバーが動く（`get-all-desktops` が yield する場合）可能性も契約テストの前提に含める（アダプタのファイバーは `wm :set-focus` を使わないので害は無い）。失敗したら警告して続行（C 単独に退化）。
`handle-display-changed` の `(:set-focus wm cur-frame)` は A の対象外（デスクトップ切替ではない）なので、**抑止しない**。その後の
フォーカスは Jwno の選択に従い、観測（`focus-changed`）で Core が追従する。

### D8 タグとデスクトップ — 読み取り専用の対応を段階 1 から入れる（レビュー M-C）
ADR 0006（ワークスペースの実装方式）は未決だが、観測だけは決めておける。Core のタグは固定の `"1"`〜`"9"`（`install` の opts）とし、
**仮想デスクトップの番号 → タグ**の読み取り専用の対応を使う:
- 番号は Jwno の `(:get-all-desktops vd-man)`（registry を同期で読み、キャッシュする。yield しない。`[index guid name]` の列で、index は 1 始まり）の
  `index`。デスクトップをまだ作っていない環境では列が空で、既定の 1 つ → `"1"`。guid の書式は Jwno の `format-guid`（大文字・波括弧付き）に
  そろえる（`win32` の `GetWindowDesktopId` の結果も同じ書式に直す）。
- **対応できない VD（番号が 10 以上、キャッシュにない guid）の窓は Core に渡さない**（`window-seen` を流さず、snapshot から除く。既知なら
  snapshot から消えることで幽霊として除去される）。**tag nil は ADR 0005 の本来の意味（本当に不明）だけに使い、ここでは使わない**
  （使うと別の VD の窓が見えているワークスペースに入る）。guid の照合に失敗したら、アダプタが `(:get-all-desktops vd-man true)`
  （同期）でキャッシュを読み直してからもう一度照合する（新しい VD の作成直後や、切替を伴わない削除でキャッシュが古い場合に備える）。
- Core のタグは `"1"`〜`"9"` と、**予約タグ `"0"`**（窓は入れない。keymap の既定束縛は先頭の 9 個だけなので束縛されない）。
  `virtual-desktop-changed` の guid が引けない（対応できない VD にいる）ときは `[:desktop-changed "0"]` を流す。Core から見える窓が無く、
  見えない VD の窓へ `:focus` を出さない。
- **起動時**（ADR 0009 R-7 を改訂）: `start` は `windows-observed` より**前に** `[:desktop-changed (current-desktop)]` を流す（引けなければ
  `"0"`）。流さないと Core の `:current` が `"1"` のまま OS とずれ、最初の `:focus` が暗黙のデスクトップ切替を起こす（レビュー N1）。
- `window-created` の `desktop-info :id`、snapshot の窓ごとの guid（`win32` の `GetWindowDesktopId`）、`virtual-desktop-changed` の `guid` から
  tag を引く。`virtual-desktop-changed` は `[:desktop-changed tag]`。Core の R1・T2・`windows-observed` の tag 修正がそのまま効くので、
  ワークスペースごとの順序とフロートの切替は VD の往復で失われない。
- Core は見えているワークスペースの窓にしか `:focus` を出さない（Q5）ので、暗黙のデスクトップ切替は起きない。
- **`:goto` / `:send` は束縛せず、ポートは投げる**（段階 1 ではユーザーが命じない限り Core は出さない）。VD の作成・削除・並べ替えによる
  番号のずれは段階 2 で扱い、段階 1 では「ずれたら snapshot で直る」程度とする。これは ADR 0006 の案 1（VD = ワークスペース）の
  読み取り側だけを先取りする。案 2（自前の hide/show）が選ばれたら対応は作り直す。
- **段階 2**（ADR 0006 の決定後）: `:goto`/`:send` の実装、A の本番運用、番号のずれへの対処。

## Consequences
- 良い: Jwno の配置を無効化するので、二重配置・retile の上書き・フロートの復元・点滅が消え、D2 の再主張が `:refresh` だけで済む。
  Jwno の変更の影響が `adapter.janet` と `win32.janet` に閉じ、ポート・フック変換・A はフェイクで Linux テストできる。
- 悪い: `:swp-flags` は Jwno の内部実装（tags の仕様）への依存で、Jwno の版に結合する（版を固定し、自己診断する）。`install` より前から
  木にある窓と、layout-history の復元（`window-load`）で tags が消えた窓にはタグが無いので、`install` 時とポーリングのたびに立て直す。
- 悪い: `transform-hwnd` は `:swp-flags` に関係なく `reset-hwnd-visual-state` を呼ぶ。**Jwno の transform が走るたび（作成時・retile・
  `:frame-activated` からの retile）に最大化が解除される**。タイルは Core が置き直すので害は無いが、最大化したフロートはディスプレイ変更で
  元に戻る。許容するか契約テストで確かめ、許容するなら ADR 0007 の互換表に差異として書く。
- 悪い: API 名・座標規約・フック引数・`tree-node-get-window-stack` の挙動は、ソースを読んだだけで**実機未検証**。
- 悪い: 最小化・タイトル変更の反映はポーリング間隔だけ遅れる。ユーザーのドラッグは戻らない（`window-moved` 未対応）。
- 悪い: Jwno が管理しない窓（昇格・topmost・immovable）は Core から見えない。HWND の再利用で、Jwno の `clean-up-hwnds` の前に古い window
  オブジェクトが新しい窓として列挙されることがある（まれ）。
- 悪い: `transform` は失敗を握りつぶすので、`:place` の読み戻し検査（D4）でしか失敗を検出できない。ADR 0009 R-3/R-8 はアダプタでは
  主に幽霊と読み戻しの不一致にしか効かない。`:focus` の失敗は観測（R-4/R-10）で補う。

## Confirmation
- 段階 1（Linux、フェイク `context` / `win32`）: ポート→Jwno 呼び出しの対応（矩形変換、`@{:swp-flags 0}`、読み戻し）、フック→event の変換
  （値の取り出し・spawn で遅延・nil・GA_ROOT 正規化）、A のラッパー（`defer` の範囲・例外時の解除・アダプタの `:focus` が抑止されないこと）、
  VD 番号 → tag の対応（空の列・範囲外・不明な guid・キャッシュの読み直し・予約タグ `"0"`）、起動時に OS が VD k にいれば start の後で Core の `:current` が k になること、`:place` の読み戻しが `window-moved` になること、ポーリングによる `:swp-flags` の立て直し、id の変換の漏れ（pointer 風の値）。
- 段階 2（Windows の契約テスト。`spike-jwno` 系のワークフローに追加）: アダプタが Jwno 0.9.16 にロードできること（`import` の解決）、
  `:place` が DWM 補正込みで期待の見える矩形に置くこと、**`:swp-flags` で Jwno の初回配置・retile・復元が窓を動かさないこと**、**最大化した窓の扱い**、`desktop-info` の guid と `get-all-desktops` の対応・`GetWindowDesktopId`、読み戻しの許容値（DPI の丸め）、
  Jwno が管理した窓の hwnd と `GA_ROOT` の一致（UWP を含む）、`window-created` が既存窓にも発火すること、A の (a)〜(d)（ADR 0009 A-4）と
  `wm :set-focus` がその 1 か所のみであること、`:monitor-updated` 後の再主張、ポーリングが最小化とフルスクリーンを拾うこと。
- 段階 3: 実機チェックリスト（`docs/`）。ホスト型 Windows Server でなく Windows 10/11 のデスクトップで。

# 0008. ウィンドウの振り分け（tile / float / ignore）とフロート管理

- 状態: Proposed（Accepted（改訂 4。Opus レビュー 3 回で収束、2026-10-31。Core は実装・検証済み（F1〜F11 のプロパティ、X1 拡張を除く）。Shell 規約は Windows 未検証））
- 日付: 2026-10-31

## Context

ADR 0007 §3 で「管理対象ウィンドウの定義」が未決だった。純関数 `classify`（`src/core/classify.janet`）
とキーマップのデータ化（`src/core/keymap.janet`）は、状態を変えない葉のモジュールとして
実装・テスト済み。残るのは **`classify` の結果を `update` にどう接続するか**で、これは state の形を変える。

`classify rules facts -> :tile | :float | :ignore`。facts は Shell が集める事実のデータ
（クラス名・exe・タイトル・ダイアログか・最小化か・フルスクリーンか・オーナー付きか）。

## Considered Options

1. **Core に `[:window-seen id facts &opt tag]` を入れる。** `update` が `classify` を呼び、
   `:tile` なら従来の `window-opened`、`:float` なら state の `:floating` に記録（配置しない）、
   `:ignore` なら管理から外す。ルールは state の設定（不変データ）に持つ。
2. Shell が `classify` を呼び、`:tile` のときだけ `window-opened` を送る。→ ADR 0001 の規則
   （WM 状態の判断は Core）に反する。さらにフロートが状態として残らない。
3. `:float` を `:ignore` と同一視する。→ 最も単純だが、xmonad の `float`／`sink` 相当の操作
   （`:toggle-float`）ができない。

## Decision（改訂 4。Opus レビュー 1 回目の指摘を反映）

案 1。xmonad の実装に倣い、**フロートはスタックに残し、レイアウトに渡すときだけ除外する**
（xmonad の `windows` は `W.filter (notMember floating)` でタイル対象を作る）。focus・
`actionable?`・I1・I2・並べ替え・X1 は変えない。**分類は管理開始時に 1 回だけ**
（xmonad の manageHook と同じ）。以後は `:ignore` への出入りだけを反映する。
`:auto` は持たない（レビュー §4。再分類によるスラッシングとユーザー切替の上書きを避ける）。

### state
- `:rules` — tuple of struct。`st/make` が `valid-rule?` で検査し、不正なら assert
  （設定ミスは起動時に落とす。event では投げない）。既定は空。
- `:floating` — `{id true}`。`ws :ids` の部分集合。`:send` で保持される。常に struct として持つ
  （空は `{}`。等価比較が安定する）。
- **`placements(s)` = スタックから全フロートを `ws/remove` で除いた workspace を arrange した結果**
  （F7。nmaster・順序・Full がタイル対象だけで決まることの定義）。
- **effect の導出（`derive-effects`, `all-places`）は `placements` のキーについてだけ回す。**
  `:ids` を回してはならない（フロートに `[:place id nil]` が出るため。レビュー H1）。

### events
- `[:window-seen id facts &opt tag]`。`facts` が dictionary でなければ **event ごと無視**（E9）。
  `c = classify(rules, facts)`:
  - 未知の id: `:ignore` は何もしない。`:tile` は `window-opened` と同じ。`:float` は
    `window-opened` の後、**id が known になったときだけ** `:floating` に追加
    （`open-window` が不正なタグ・id を拒否したら何もしない。F1）。
  - 既知の id: **`classify.hidden?(facts)`**（状態 facts のみ: `visible? false` /
    `minimized?` / `fullscreen?`。全域）が真なら除去
    （`close-window` + `:floating` 掃除）。**ユーザールールは管理開始時（未知の id）にだけ適用する**
    ため、`:title` ルールによる除去↔再挿入の往復は起きない。
    **hidden でなければ何もしない**（タイル⇄フロートの再分類はしない。`:toggle-float` が残る）。
    **`classify` は `hidden?` を最初に評価する**（`hidden?` → `:ignore`、次にユーザールール、
    次に builtin の ignore（`tool-window?`）/float、最後に `:tile`）。したがってユーザールールは
    状態 facts による ignore を覆せない（C2/C3 を「状態 facts は常に :ignore。ユーザールールはその後」
    に改める）。`tool-window?` は静的な属性なので、従来どおりユーザールールの後に残す。
    これで管理開始時の判定と既知 id の除去が一致し、`window-seen` の冪等性（F3）が構造的に成り立つ
    （レビュー r3 N1）。
  - 除去された id が `:os-focus` と等しいときは、`:os-focus` を保ったまま
    **`:external-focus true`**（OS のフォーカスは管理外にある、という観測そのもの。E11 により
    `:focus` は出ない。フルスクリーン動画からフォーカスを奪わない。レビュー H2）。
    E10 の「external を立てる観測」に `window-seen` の `:ignore` 遷移を加える。
  - それ以外の除去は `close-window` と同じ（モデルのフォーカスが隣へ移れば `:focus` を出す）。
  - 最小化から復帰（`:ignore`→未知→`:tile`）は新規ウィンドウとして扱う（insertUp）。位置は
    覚えない。xmonad も unmap で unmanage するため互換。
  - 非 silent（`window-opened` と同じ。新規ウィンドウには E4 の `:focus`）。
- `window-opened` は **テスト用の糖衣**（`:tile` 固定の `window-seen`）として残す。
  **Shell の規約: 1 つの id には `window-seen` だけを送る**（併用すると、ダイアログが一度タイル
  されたり、ignore 済みが再タイルされる。レビュー M6）。
- `[:windows-observed [[id tag &opt facts] ...]]`: facts があれば各要素を `window-seen` と同じ
  関数で扱う（既知の id は `hidden?` のときだけ除外、それ以外は触らない。未知は分類して追加）。
  facts の無い要素は従来どおり。silent。R4 は「モデル = 観測集合 − 有効な facts で除外と判定された
  もの」。**不正な facts の要素は「facts の無い要素」として扱う**（集合には含め、分類だけをしない。
  捨てると幽霊として削除されてしまうため）。

### commands
- `:toggle-float`: フォーカス中のウィンドウの `:floating` を反転。**actionable のときのみ**。
  スタックの順序とフォーカスは変えない（F9。xmonad の `float`/`sink` は `floating` しか触らない）。
  `:misfit` の該当 id を消す。タイル→フロートでは当該ウィンドウに `:place` を出さず、残りが
  タイルし直される。フロート→タイルで当該ウィンドウに `:place` が出る。
- 並べ替え・`focus-next` 等はスタック全体に作用する（フロートを飛ばさない。xmonad と同じ）。
- `:toggle-float` を `command-args` に `:none` で加える。K3 は例外に `:toggle-float` を加える
  （xmonad の既定束縛に toggle は無い。`mod-t` は sink のみ）。`st/make` は任意の第 3 引数
  `rules`（既定 `[]`）を取る。既存の 2 引数呼び出しは変わらない。
- `window-closed` と snapshot の幽霊削除は `:floating` と `:misfit` の該当 id も消す（HWND 再利用対策）。

### 差異・制限（ADR 0007 §2 に追記する）
- (g) 分類は管理開始時のみ（xmonad の manageHook と同じ）。facts が後で変わっても、
  「hidden（不可視・最小化・フルスクリーン・ツール）への遷移」以外は反映しない。タイトル変化による
  フロート化は `:toggle-float` で行う。`:title` ルールは **管理開始時点のタイトルにだけ**一致する
  （作成直後は空のことがある。xmonad の Spotify 問題と同じ既知の制限）。
  `:toggle-float` の結果と挿入位置は、最小化→復帰・Jwno のリロードで失われる（覚えない）。
- (h) Full は全タイルを画面矩形に重ね、見えるものは Shell の z 順に依存する。xmonad は
  フィルタ後のスタックのフォーカスを 1 枚だけ表示する。実害は小さい。
- (i) fullscreen は `classify` の C3 のとおり `:ignore`（xmonad の `doFullFloat` = 管理したまま
  フロート、とは違う）。H2 の対策でフォーカスは奪わない。管理したままフロートにする案は
  将来の選択肢として残す（C3 の変更を要する）。

### Shell への規約（**Windows 未検証**）
- `facts.fullscreen?` は「アプリが要求したフルスクリーン」とし、Core 自身が置いたタイル
  （タスクバー自動非表示で作業領域 = モニター矩形になる）と区別できる形で判定する。
  さもないと「配置→fullscreen 判定→ignore→再挿入」のループが起きうる。
- 最初の `window-seen` は可視になった時点（`EVENT_OBJECT_SHOW`）まで遅らせる（タイトルが確定し、
  非表示で作られるアプリを扱える）。HIDE／cloak と最小化・フルスクリーン・破棄の通知は Jwno のフックに無い。Shell が独自の WinEvent フックを
  持つ。`window-seen` を送った id には、破棄時に必ず `window-closed` を届ける（Jwno は管理外の
  ウィンドウに `:window-removed` を出さない）。
- H2 の対策は `:os-focus` があることが前提。`:goto`／`:desktop-changed` 直後の `:os-focus` 空白は、
  規約 4（直後に `GetForegroundWindow` を観測）で埋める。
- z 順（フロートを前面に出す）は Shell の責務。Jwno の frame がフロートを動かさないかは
  ADR 0004 のスパイクで確認する。

## Consequences

- 良い: 振り分けとフロートが Core の純粋なロジックになり、プロパティで検査できる。
  フロートはスタックに残るので I1・I2・actionable?・X1 は変わらない。
- 悪い: state に `:rules` `:floating` が増える。観測原則の改訂箇所は 2 つだけ:
  ADR 0005 §1 の「external を立てる観測」と INVARIANTS E10 に、`window-seen` の
  hidden 遷移（`:os-focus` 一致時）を加える。
- 悪い: 分類は管理開始時のみ（差異 (g)）。タイトル依存のルールは弱い。

## Confirmation

`docs/INVARIANTS.md` に Draft として追記する不変条件:
- F1 `:floating` のキーは、どれもスタック内のウィンドウ。`window-closed`／幽霊削除の後、その id は
  `:floating`・`:misfit` に残らない。close 後の同じ id の `window-seen` は新規扱い（HWND 再利用）。
- C4 任意の rules・facts について、`hidden?(facts)` ならば `classify(rules, facts) = :ignore`。
- F4 既知の id への `window-seen`（hidden でない facts）は state も effects も変えない。
- F2 全 effect（`:refresh` を含む）の `:place` は矩形が `valid-rect?` で、id は `:floating` に含まれない。
  （E1 の `nil = nil` に頼らない直接の検査）
- F3 `window-seen` は E6（冪等性）の対象。
- F5 `:ignore` と分類されたウィンドウは、スタック・`:floating`・`:misfit` に残らない
  （`:os-focus` は観測なので残ってよい）。
- F6 `:toggle-float` の結果は、hidden でない任意の facts の `window-seen` / facts 付き `windows-observed` の再送で戻らない。
- F7 `placements(s)` = 全フロートを除いた s' の `placements`。I5〜I7 は F7 経由で既存の検査を使う。
- F8 `:os-focus` と同じ id が `:ignore` に遷移したら `:external-focus` が立ち、`:focus` effect は出ない。
- F9 `:toggle-float` はスタックの順序とフォーカスを変えない。2 回（actionable を保つ）で
  `:floating` は元に戻る。
- F11 不正な facts の `window-seen` は state を変えない。`windows-observed` の不正な facts 要素は、facts の無い要素と同じ結果になる。
- X1 拡張: フロートを混ぜたランダム列で、`floating` 集合と `filter` を加えた参照モデルとタイル列が一致。
- 生成器に `window-seen`（不正 facts を含む）、`:toggle-float`、facts 付き `windows-observed`、
  ランダムな `:rules` を加え、I0〜I7（F7 経由）・E3〜E13・R1〜R4 をフロート込みで維持する。
- 実装前に Opus の再確認を通し、収束してから Accepted にする。

## 実装上の注意
- facts 付き snapshot で、既知かつ hidden の id は `seen` に入る。幽霊削除とは別に、明示的に除去する。

## 追記（2026-10-31）: `[:window-dragged id rect]` — ユーザーのドラッグ／リサイズはフロート化
xmonad の `mouseMoveWindow`/`mouseResizeWindow` は、ドラッグ／リサイズした窓を `float` する。Shell（ADR 0010 D9）がドラッグ／リサイズの**終了**を観測したとき（および
最大化されたタイルをポーリングで見つけたとき）、`[:window-dragged id rect]` を流す。`rect` はそのときの**見える枠**（`:place` と同じ座標系）。

Core は、`id` が**可視ワークスペースの既知のタイル窓**で、かつ **`rect` がモデルの配置（`placements`）と違うときだけ**、`:floating` に入れる（`:toggle-float` と同じ遷移。
対象が明示された観測なので actionable を要さない）。`rect` が配置と同じ（タイトルバーを動かさずにクリックしただけ）なら何もせず、`:misfit` を消すだけ（`window-moved` の
一致と同じ）。位置は動かさず（ユーザーが置いた所にとどまる）、残りのタイルを詰め直す。次の場合は何もしない（冪等。E9）: 不正な id・不正な `rect`、未知の窓
（`:ignore` と分類された窓も state に無いのでここに含まれる）、不可視ワークスペースの窓、すでにフロートの窓。`:pending-focus` とフォーカスには触れない
（silent な観測ではないが、フォーカスは変わらない）。

不変条件: D1 `window-dragged` は、配置と違う `rect` のタイル窓をフロートにし、スタックの順序・フォーカス・`:os-focus`・`:external-focus` を変えない／D2 配置と同じ `rect` の
タイル窓は state の `:floating` を変えない／D3 二度目は state も effects も変えない（E6）／D4 effects に `:place` を出すのは残りのタイルだけで、ドラッグされた窓には出ない（F2）／
D5 `:external-focus` を下ろさない（E10。`non-focus-observation` に加える）。

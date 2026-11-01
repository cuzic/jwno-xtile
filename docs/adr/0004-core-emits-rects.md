# 0004. Core は Frame 操作ではなく矩形を出力する

- 状態: **Accepted**（2026-11-01。矩形の配置は、ホスト型 Windows と実機（Windows 11）の契約テストで 0 px 差を確認。Opus 指摘 R8 反映済み）
- 日付: 2026-10-31

## Context

Jwno はウィンドウを Frame ツリーで管理し、`:retile` 等で位置を決める。Core は xmonad の
StackSet 的なモデルで「各ウィンドウの矩形」を決める。橋渡し方式が未決。

**Jwno の実装上の制約（~/jwno-xtile-ref/jwno/src/win.janet を確認）**:
- `:window-created` / `:window-removed` フックは `:filter-window` を通過した **管理対象の
  ウィンドウにしか呼ばれない**。
- 管理対象にすると、Jwno は追加時に必ず `:transform` で Frame の矩形へ配置し、モニタ更新
  時にはツリー全体を retile する。

## Considered Options

1. Shell が矩形を `window :transform` で直接適用する。Jwno の Frame ツリーは使わない。
   → **そのままでは成り立たない**: 生成・消滅の通知を得る手段が無い（Jwno に管理させれば
   二重配置・retile での上書きが起きる）。ウィンドウ生成の通知元を別に用意する必要がある
   （自前の WinEvent フック等。`:filter-window` の副作用利用は呼び出し回数が不定で危険）。
2. Core が Frame ツリー（分割方向・比率）をデータとして出力し、Shell が Jwno の Frame へ
   機械的に反映（reconcile）する。Jwno の機能と整合するが、**effect の語彙が変わる**ため
   ADR 0001 の語彙規則（Jwno 固有の概念を持たない）に抵触する。採るなら 0001 を改訂する。
3. 1 ウィンドウ 1 Frame とし、Core の矩形を `frame :transform` で与える。Jwno の
   イベント機構を使えるが、retile 時に矩形を保持できるかが未確認。

## Decision

未決。現時点の実装は「Core は `[:place id rect]` を出す」まで（案 1・3 に共通）。
スパイクの確認項目（順序どおり）:

1. **管理対象外ウィンドウの生成・消滅を何から受け取るか**（案 1 の成否を決める）。
   案 3 なら Frame の矩形が retile 後も保持されるか。
2. Jwno の自動 retile（モニタ変更・DPI）とウィンドウ位置が喧嘩しないか。
3. 手動で位置を変えられた場合に `[:window-moved id]`（ADR 0005）で戻せるか。
4. `layout-history` を使うか捨てるか。
5. **Jwno 自身のフォーカス操作との競合**: Jwno はデスクトップ切替時に自分で `:set-focus` を
   呼び、管理対象がフォーカスを受けると `:activate` で Frame をアクティブにする。Core の
   `:focus` と競合し、通知の順序問題（ADR 0005）を悪化させる。これらの副作用を止められるか、
   または観測イベントとして扱えるかを確認する。
6. ADR 0005 §1 の前提: `:goto` や `:focus` の後にフォーカス通知が届くか（Jwno は同一 hwnd の
   通知を重複排除する）。

## Consequences

- Core の `update` 境界（event/effect の形）は変えない。案 2 を選ぶ場合のみ effect 語彙が
  変わるので ADR 0001 を改訂する。

## Confirmation

- 実機チェックリスト（`docs/`）に上記 4 点を追加し、結果を追記して Accepted にする。

## スパイク記録（GitHub ホスト型 Windows ランナー）

### 2026-10-31 ビルド（`.github/workflows/spike-jwno-build.yml`、実行 41184729632）
- `windows-2022` で Jwno 0.9.16（758edf3）をビルドできた。Janet 1.40.1（Jwno の固定版）、jpm 207ebf3、
  jw32 master（8bd813a）、MSVC 17.14 / SDK 10.0.26100.0。所要約 1 分、`jwno.exe` 約 2 MB。
- 最初の失敗は `JANET_SOURCE_PATH` 未設定（Janet ソースの checkout が必要）。
- 起動・フック発火・DWM の枠・仮想デスクトップ・フォアグラウンドロック・`window-removed` の取りこぼしを
  実測した（`docs/spike/2026-10-31-hosted-windows.md`。**Windows Server 2022 のホスト型ランナーであり、
  実機のデスクトップではない**）。
- 追加シナリオ（run 2）: 手動で動かした窓は `retile` で枠に戻される（確認項目 2〜3 の一部）。Jwno の
  `transform` は DWM の枠を補正して配置する。フォーカス通知は欠落・遅延し、新規ウィンドウでは
  `window-created` との順序が一定でない（項目 6）。
- **項目 5（競合）を測定した**（`docs/spike/2026-10-31-hosted-windows.md`）。Jwno は、レイアウトのある
  デスクトップへ切り替わるたびに自分で `set-focus` を呼び、切替から約 100ms 以内の Core 相当の `:focus` に勝つ。
  それ以降の `:focus` は通る。別デスクトップの窓への `SetForegroundWindow` は暗黙のデスクトップ切替になる。
  → 緩和策 A/B/C を実測で比較した（ADR 0009 の未決事項。なしは 0/10、A は 10/10、B は 150ms 以上で 10/10、C は 10/10 だが点滅）。
- **まだ未測定**: 項目 1（管理対象外ウィンドウの通知元）、`window-moved` の戻し、`transform` と自前
  `SetWindowPos` の比較。緩和策は実機での再確認。

## ADR 0010 との関係（2026-10-31）
ADR 0010（Jwno アダプタ）は案 1 の変種を**条件付きで**採る: Jwno に窓を管理させつつ、窓の tags の `:swp-flags`
（`SWP_NOMOVE|SWP_NOSIZE`）で Jwno 自身の配置・retile・復元を無効化し、Core の矩形だけを `window :transform` で適用する。
上の「そのままでは成り立たない」の反論（二重配置・retile での上書き）への答えがこれ。条件は ADR 0010 の契約テスト（Windows）で
二重配置・retile・最大化を確かめること。それが済むまで本 ADR は Proposed のまま。

### 契約テストの結果（2026-10-31、ホスト型 Windows Server 2022。実機ではない）
ADR 0010 の条件のうち、二重配置と retile は確認できた: `:swp-flags` で Jwno の配置を無効化すると、retile は窓を動かさず、Core の矩形は DWM の見える枠で
完全に一致する。最大化した窓は retile で解除される（残る差異）。上の確認項目 1（管理対象外ウィンドウの通知源）は、アダプタが「Jwno が管理する窓だけを
Core の対象にする」ことにしたため、本質的には回避している。**Windows 10/11 実機での確認が済むまで Proposed のままにする。**

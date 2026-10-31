# 0001. Functional Core / Imperative Shell を採用し、WM 状態の判断はすべて Core に置く

- 状態: Accepted（Opus レビュー 5 回で収束、2026-10-31。Shell 側の実装・実機検証は未了）
- 日付: 2026-10-31

## Context

Jwno 上で xmonad ライクな WM を作る。参考にした jwno-layout-tall は、レイアウト
ロジックの一部は純粋だが、デスクトップ操作・起動時の取り込み・フォーカス補正などが
Jwno/FFI と混在しており、検証には Windows 実機が要る。開発環境は Linux で、AI エージェント
がコードを書く。エージェントが自力で確認できるのは「ここで実行できるテスト」だけである。

## Decision Drivers

- 判断ロジックを網羅的に自動テストしたい（ユーザー要件）。
- Shell を薄くし、Windows 実機でしか確認できない部分を最小化したい。
- Jwno は 1.0 前で API が壊れうる。壊れる面積を小さくしたい。

## Considered Options

1. **FCIS**: 純粋な `update(state, event) -> {state, effects}`。Shell は変換と実行のみ。
2. Jwno のフック内で Frame ツリーを直接操作（`auto-layout.janet` 方式）。
3. 層は分けるが Core が Jwno オブジェクトを受け取る。

## Decision

案 1。

### 規則
- **WM の状態についての判断は Core に置く。** 「どのウィンドウが何番目か」「次に誰に
  フォーカスするか」「どこに置くか」「閉じてよい対象か」は Core。
  OS 呼び出しの成否・値の形式変換・列挙の取りこぼし処理のような **OS 境界の分岐は
  Shell に置いてよい**（Shell が `if` を持つこと自体は禁止しない。判断基準は上の一行）。
- `src/core/` は I/O・FFI・Jwno の import を持たない。入出力は不変データのみ。
  **不変性は `merge` では保証されない**（Janet の `merge` は struct 同士でも可変の table を
  返す）。状態更新は `data/assoc` を使い、プロパティテスト I0 で検査する。
- 公開境界は `(update state event) -> {:state :effects}` の一本。**Core は入口で入力を検証し**
  （id は数値／キーワード／文字列のみ、矩形は整数で幅・高さ > 0、など）、不正な event は
  無視する。どんな入力でも投げない（E9）。可変値は state に入れない（I0）。
- ウィンドウ ID は不透明、矩形は整数ピクセル `{:x :y :w :h}`。
- `:place` / `:focus` は新旧 state の差分から導出する。差分方式の限界（実画面とずれる）は
  ADR 0005 の回復手段（`:refresh`, `:window-moved`）で補う。
- **観測原則**（ADR 0005）: OS についての事実は観測イベントからのみ入る。OS が起こした変化
  （`:focus-changed`, `:desktop-changed`）はモデルだけ更新し `:focus` effect を返さない。
  external focus を下ろせるのは観測だけ。`:current` を変えてよいのは `:desktop-changed` と
  `:goto` だけ。
- **effect の語彙は Jwno 固有の概念を持たない**（`:place` / `:focus` / `:close` /
  `:goto` / `:send` のように、WM 一般の言葉に限る）。語彙の変更（例: Frame ツリーを出す）
  はこの ADR の改訂を要する（ADR 0004 参照）。

### Shell の構造
- Shell は `jwno/context` 等を **引数で受け取る** 関数群とし、Linux でもロードできる
  ようにする（依存注入）。jw32/FFI の import は最外殻の薄いファイルに限る。
- 実行規約（state を保存してから effect を実行、再入禁止のキュー、`protect`）は ADR 0005。

## Consequences

- 良い: Linux 上で WM 状態の全判断を単体・プロパティ・差分テストできる。
- 良い: Jwno API 変更の影響が Shell に閉じる。
- 悪い: Core が Jwno の機能（Frame、`layout-history` 等）を再実装する領域が出る。
  二重管理のリスク（ADR 0004）。
- 悪い: 差分導出は実画面の状態を知らない。回復は ADR 0005 の規約に依存する。
- 悪い: Shell は Core のテストでは検証されない。残余リスクは ADR 0003 の
  契約テスト／実機チェックリストで扱う。

## Confirmation

- `mise run test` が通る。現状: 例示テスト多数 + プロパティ/差分テスト（`test/property-test.janet`,
  `test/model-test.janet`）。**カバレッジは未計測**で、件数は網羅性の根拠にならない。
- 純粋性は `test/purity-test.janet` が機械検査する: (1) import は `./` のみの許可リスト方式、
  (2) `os/ file/ ffi/ ev/ net/ math/rng ...` など非純粋なシンボルを一切使わない。

# power-mode

macOS の通常時の電源設定を初期化し、必要な間だけアイドルロックやスリープを一時抑止するスクリプトです。

| モード | 使う場面 |
| --- | --- |
| `auto` | `setup` で反映した普段使いの設定に戻す |
| `awake` | 画面をロックしても、本体で処理を続ける |
| `awake-remote` | 離席中も Codex などの GUI 操作を続ける |
| `awake-lid-closed MINUTES` | MacBook の蓋を閉じても、指定した時間だけ起動を維持する |

## 使い方

```sh
# dotfiles の local-bin wrapper を有効化済みならこちら
power-mode
power-mode --detail
power-mode setup
power-mode auto
power-mode awake
power-mode awake-remote
power-mode awake-lid-closed 120

# 現在の power mode だけを確認
./power-mode status

# 現在の power mode と関連設定を詳しく確認
./power-mode status --detail

# 通常時の電源設定を初回または変更時に反映
./power-mode setup

# 普段使い向け
./power-mode auto

# 本体の自動スリープを抑止。この後 Control + Command + Q で画面をロック
./power-mode awake

# リモート操作向け
./power-mode awake-remote

# 低電力モードで蓋を閉じてもスリープさせず、120 分後に auto へ自動復帰
./power-mode awake-lid-closed 120

# 実行内容だけ確認
./power-mode awake-remote --dry-run
```

`status`（引数なしでも同じ）は `auto` / `awake` / `awake-remote` / `awake-lid-closed` / `custom` / `unknown` のいずれかの現在のモードだけを表示します。`status --detail` または `--detail` を付けると、現在の電源状態に対応する `pmset` 設定、スクリーンセーバー設定、擬似スクリーンセーバーの動作状態も表示します。
各モードの通常実行は適用後のモードだけを表示します。詳細を確認したい場合は、`power-mode status --detail` を実行してください。`--dry-run` は実行予定のコマンドだけを表示します。

既存のスクリプトからは `normal`、`lockawake`、`nolock`、`nosleep` もそれぞれ対応するモードの別名として使えます。

`setup` による `pmset` の変更には sudo が必要です。
スクリプト全体を `sudo power-mode ...` のように実行しないでください。`pmset` だけ内部で sudo します。
Codex などの非対話環境では sudo のパスワードを入力できないため、`setup` は Terminal などの対話可能なシェルから実行してください。
一度 `setup` を実行した後は、`auto`、`awake`、`awake-remote` の間をパスワード入力なしで切り替えられます。
`awake-lid-closed` の開始時と、自動復帰前に別のモードへ切り替えるときは、`pmset powermode` と `pmset disablesleep` を変更するため sudo が必要です。

## 既定値

### `auto`

- 適用先: 全電源
- システムスリープ: 30 分
- ディスプレイスリープ: 20 分
- ディスクスリープ: 10 分
- スクリーンセーバー: 15 分
- スクリーンセーバー/ディスプレイ消灯後のロック設定: 変更しない

`auto` は 15 分間操作がないとスクリーンセーバーを起動し、20 分でディスプレイを消灯します。復帰時のパスワード要求は macOS の現在のロック設定に従います。

### `awake`

`power-mode awake` を実行してから、`Control + Command + Q` で画面をロックします。通常のスクリーンセーバー設定に戻り、ディスプレイは macOS の設定に従って消灯します。モード有効中は、画面のロック状態にかかわらず `caffeinate -i` が本体のアイドルスリープを抑止します。

`caffeinate` は現在の GUI ログインセッションで動きます。`power-mode auto` などで別のモードへ切り替えるか、ログアウトすると終了します。蓋を閉じる操作や Apple メニューからの手動スリープは macOS の通常の動作に従います。

### `awake-remote`

- 通常時の `pmset` 設定: 変更しない
- システムスリープ: `caffeinate` で一時抑止
- ディスプレイスリープ: `caffeinate` で一時抑止
- ディスクスリープ: `caffeinate` で一時抑止
- macOS 標準スクリーンセーバー: 無効
- 擬似スクリーンセーバー: 5 分
- 擬似スクリーンセーバー表示中の輝度: 1%
- 外部ディスプレイの表示復帰時の輝度: 50%
- スクリーンセーバー/ディスプレイ消灯後のロック設定: 変更しない

`awake-remote` は通常時の `pmset` 設定を上書きせず、擬似スクリーンセーバーの実行中だけ `caffeinate -dims` でシステム、ディスプレイ、ディスクのアイドルスリープを抑止します。macOS 標準スクリーンセーバーは無効化し、代わりに通常の AppKit アプリとして動く擬似スクリーンセーバーを常駐させます。5 分間操作がなければ全ディスプレイを黒いウィンドウで覆い、表示中はマウスポインタも隠します。時計の表示と移動は、描画負荷を抑えるため毎秒 1 回更新します（`awake-remote` / `awake-lid-closed` 共通）。同時に内蔵ディスプレイと対応する外部ディスプレイの輝度を 1% まで下げます。マウスやキーボード入力を検知すると、内蔵ディスプレイは退避した元の輝度へ、外部ディスプレイは 50% へ戻したうえでウィンドウを隠し、マウスポインタを再表示します。標準スクリーンセーバーの保護画面には入らないため、Codex の GUI 操作を妨げません。

外部ディスプレイの制御には `m1ddc` を使います。BenQ EW3270U と現在の接続経路では DDC の書き込みは成功しますが、輝度の読み取り値が常に `0` になり、元の値を取得できません。そのため外部ディスプレイだけは読み取り値を退避せず、表示復帰時に既定の 50% を明示的に書き込みます。輝度を下げる前にディスプレイ UUID と復元値を `~/Library/Caches/power-mode/` へ記録します。保存対象が 1 台で、その UUID で復元できない場合は既定の外部ディスプレイを 50% にするフォールバックを試します。複数台では復元に失敗したディスプレイの状態だけを残します。フォールバック、状態の解析、または `m1ddc` の実行に失敗しても警告を表示してモード切り替えは継続します。

擬似スクリーンセーバーは初回起動時、Swift ソースを `~/Library/Caches/power-mode/` にコンパイルします。`auto` に戻すと常駐プロセスと `caffeinate` が終了し、`setup` で設定した通常の電源設定がそのまま有効になります。`auto` / `awake-remote` は `sysadminctl` やパスワード要求設定を変更しません。`awake-remote` でも手動ロックなどは抑止せず、パスワード要求は macOS の現在の設定に従います。

擬似スクリーンセーバーのソースやコンパイル設定を変更した場合は、管理スクリプトで強制再ビルドまたは再起動できます。

```sh
# 強制再ビルドのみ
./pseudo_screensaver_control.sh rebuild

# 強制再ビルドして現在の待機秒数で再起動
./pseudo_screensaver_control.sh refresh

# 強制再ビルドして 5 秒後に表示する設定で再起動
./pseudo_screensaver_control.sh refresh 5
```

### `awake-lid-closed`

- 継続時間: コマンド引数で分単位の指定が必須
- 電力モード: `pmset powermode 1` で低電力
- 蓋を閉じた時を含むシステムスリープ: `pmset disablesleep 1` で無効
- スクリーンセーバーと擬似スクリーンセーバー: `awake-remote` と同じ
- 時間切れ: 先に `auto` のスクリーンセーバー設定と常駐プロセスの停止を完了し、最後に `pmset disablesleep 0 powermode 0` でスリープを許可して電力モードを自動へ戻す
- スクリーンセーバー/ディスプレイ消灯後のロック設定: 変更しない

自動復帰では、通常設定への復帰に失敗した場合もスリープ無効の解除を試みます。復帰処理のいずれかが失敗した場合は状態ファイルを残すため、`power-mode auto` で再試行できます。

`awake-lid-closed` の自動復帰タイマーは root 権限で待機するため、sudo の認証期限が切れた後でもスリープを許可し、電力モードを自動へ戻せます。Mac を再起動すると待機プロセスも終了するため、再起動後は `power-mode auto` で明示的に通常状態へ戻してください。

`awake-lid-closed` は蓋を閉じた時のスリープを無効化しますが、macOS の画面ロック設定自体は変更しません。現在の macOS で蓋を閉じた時にロック画面へ移るかは実機で確認してください。ロック設定の自動変更にはログインパスワードの取り扱いが必要になるため、このコマンドには含めていません。

## カスタマイズ

環境変数で各値を上書きできます。

```sh
NORMAL_SLEEP_MINUTES=20 \
NORMAL_DISPLAY_SLEEP_MINUTES=5 \
NORMAL_SCREENSAVER_SECONDS=180 \
./power-mode setup

# 擬似スクリーンセーバーを 60 秒後に起動する
power-mode awake-remote --pseudo-screensaver-seconds 60
```

主な変数:

- `NOLOCK_SCREENSAVER_SECONDS`
- `NOLOCK_PSEUDO_SCREENSAVER_IDLE_SECONDS`
- `NORMAL_SLEEP_MINUTES`
- `NORMAL_DISPLAY_SLEEP_MINUTES`
- `NORMAL_DISK_SLEEP_MINUTES`
- `NORMAL_SCREENSAVER_SECONDS`
- `NORMAL_PMSET_SCOPE`

`NORMAL_PMSET_SCOPE` は `setup` で反映する `pmset` の適用先です。

- `-c`: AC 電源
- `-b`: バッテリー
- `-a`: 全電源

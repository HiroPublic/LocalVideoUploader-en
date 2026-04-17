# iPhoto2YouTube

ローカル動画ファイルを入力にして、YouTube 非公開アップロードまわりを Python CLI で先行検証する試作です。

## 現在できること

- YouTube への `private` アップロード
- タイトル、説明欄、タグの自動生成
- プレイリストの存在確認、必要時の自動作成、動画追加
- OAuth 認証、認証先チャンネル確認、期待チャンネルガード
- アップロード前プレビュー確認
- 重複アップロード防止
- 履歴 DB / 管理 DB / CSV 台帳への保存
- 履歴一覧 / 詳細表示
- 管理 DB 検索
- YouTube 側メタデータ検証
- 過去レコードの backfill
- 実行サマリー / 実行履歴表示
- YouTube API エラー分類表示
- support-dir 配下 `config.json` による既定値設定
- プレイリスト公開範囲の指定
- 自動テスト
- JSON マニフェストによる複数動画の一括実行
- SwiftUI 製 macOS ネイティブ MVP
- 写真ライブラリ日付指定読み込み
- 写真ライブラリ動画の iPhone 削除
- 履歴カレンダ表示
- 撮影日基準の日次集計
- 履歴一覧の撮影日検索
- 履歴カレンダの日別手動マーク / 手動補正
- YouTube Data API `Queries per Day` 推定表示

## セットアップ

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
```

OAuth 設定は `.iphoto2youtube/client_secret.json` に置きます。  
保存先は `.env` の `IPHOTO2YOUTUBE_HOME` で変更できます。
`token.json` は `auth-login` 実行後に自動生成されます。  
動画時間と解像度の取得には `ffprobe` を利用します。

任意で `config.example.json` を参考に、`.iphoto2youtube/config.json` を置くと既定値を設定できます。

## macOS ネイティブ MVP

SwiftUI で最小構成の macOS アプリを追加しています。  
この MVP は YouTube ロジックを再実装せず、既存の Python CLI を `Process` で呼び出すネイティブフロントエンドです。

できること:

- 認証状態の即時確認と現在チャンネルの確認
- ローカル動画の複数選択
- 共通メタデータ入力
- 動画ごとの撮影日時 / 内容 / 補足上書き
- JSON マニフェスト生成
- `batch-upload` の `dry-run` / 本実行
- 実行ログ表示
- 写真ライブラリから対象日の動画読み込み
- 写真ライブラリ動画の選択追加 / 削除
- 写真画面の `Auto` 実行
- アップロード履歴一覧と詳細確認
- 履歴カレンダでの月表示、日別集計、全体集計
- 撮影日ベースのアップロード数 / 削除数集計
- 履歴一覧のキーワード検索と撮影日 `DatePicker` 検索
- 左ペインでの YouTube Data API 日次クォータ推定表示

起動方法:

```bash
swift run iPhoto2YouTubeNativeApp
```

Finder から起動したい場合:

- リポジトリ直下の `iPhoto2YouTube.command` をダブルクリックします
- 初回だけ `Release` ビルドが走り、リポジトリ直下に `iPhoto2YouTube.app` を作成して開きます
- 2回目以降は `iPhoto2YouTube.app` を Finder からそのまま開けます
- 事前に `.venv/bin/iphoto2youtube` が作成済みである必要があります

Swift パッケージの確認:

```bash
swift build
swift test
```

## 基本フロー

1. `auth-login` で Google OAuth を完了する
2. `auth-status` で OAuth セッション有無を確認し、認証先チャンネルは `current-channel` で確認する
3. `render-metadata` でタイトル、説明欄、タグを確認する
4. `upload` でプレビュー確認後にアップロードする
5. 複数本なら `batch-upload` でまとめて実行する
6. `verify-upload` で YouTube 側の反映結果を検証する
7. `history list` / `search-videos` で履歴を参照する

## 主なコマンド

```bash
./.venv/bin/iphoto2youtube auth-login --expected-channel 'Sample Channel'
./.venv/bin/iphoto2youtube auth-status
./.venv/bin/iphoto2youtube current-channel
./.venv/bin/iphoto2youtube render-metadata --video ./sample.mov --capture-datetime '2026-04-07 14:32:10'
./.venv/bin/iphoto2youtube upload --video ./sample.mov --capture-datetime '2026-04-07 14:32:10' --expected-channel 'Sample Channel'
./.venv/bin/iphoto2youtube upload --video ./sample.mov --capture-datetime '2026-04-07 14:32:10' --expected-channel 'Sample Channel' --allow-duplicate --yes
./.venv/bin/iphoto2youtube batch-upload --manifest ./batch-manifest.json --yes
./.venv/bin/iphoto2youtube search-videos --participant 'Alice' --playlist '自宅_花見' --output table
./.venv/bin/iphoto2youtube search-videos --title-contains '砧公園' --output json
./.venv/bin/iphoto2youtube runs list --limit 10
./.venv/bin/iphoto2youtube runs show --id 1
./.venv/bin/iphoto2youtube history list --limit 10
./.venv/bin/iphoto2youtube history list --limit 10 --capture-date 2026-04-07
./.venv/bin/iphoto2youtube history show --youtube-video-id 'VIDEO_ID'
./.venv/bin/iphoto2youtube verify-upload --youtube-video-id 'VIDEO_ID'
./.venv/bin/iphoto2youtube verify-upload --youtube-video-id 'VIDEO_ID' --output json
./.venv/bin/iphoto2youtube backfill
./.venv/bin/python -m unittest discover -s tests -v
```

## 運用メモ

- `auth-login --expected-channel ...` を使うと、想定外のチャンネルで認証した場合にトークンを破棄して失敗させます。
- `auth-status` はローカル保存済み OAuth セッションの有無だけを即時確認します。チャンネル名 / ハンドル / ID を確認したい場合は `current-channel` を使います。
- macOS アプリは起動時に `auth-status` を先に実行し、認証済みの場合だけバックグラウンドで `current-channel` 相当の取得を行って認証先表示を埋めます。
- macOS アプリの左ペイン `YouTube Data API` カードは、`auth-status` の応答に含まれるローカル推定値を表示します。クォータ確認のための追加 YouTube API 呼び出しは行いません。
- `Queries per Day` の推定値は `.iphoto2youtube/upload_history.db` 内の `api_quota_log` と `upload_history` を元に算出します。
- 日次クォータの積算期間は日本時間の固定日付ではなく、YouTube / Google Cloud 側の Pacific Time 基準です。夏時間中は `16:00 JST - 翌 15:59 JST`、冬時間中は `17:00 JST - 翌 16:59 JST` になります。
- クォータカードには `使用値 / 上限 / 残り / 積算終了` を表示し、内訳の先頭項目を `主因` として表示します。
- `upload` は既定で重複を検出するとスキップします。再アップロードしたい場合だけ `--allow-duplicate` を付けます。
- `upload` は実行前にタイトル、説明欄、タグ、プレイリスト、ファイルサイズ、動画時間、解像度を表示します。
- `upload --playlist-privacy-status unlisted` のように、未作成プレイリストを自動作成する際の公開範囲を指定できます。
- プレイリスト名の例:
  `[散歩] 自宅_花見` / `[旅行] 世界一周_2025` / `[旅行] ベトナム_2026` / `[旅行] 鎌倉_2026` / `[太田] 2026`
- `batch-upload` は `defaults` と `videos` を持つ JSON マニフェストを読み、複数動画を順番に処理します。
- `verify-upload` は YouTube 側のタイトル、説明欄、タグ、公開設定、処理状態、プレイリスト所属をローカル履歴と比較します。
- `backfill` は古い履歴の動画時間、解像度、ファイルサイズを再計算し、管理 DB と CSV 台帳を再生成します。
- `runs list` / `runs show` で、アップロード・スキップ・失敗件数とエラー概要をあとから確認できます。
- YouTube API エラーは `auth` `quota` `rate_limit` `permission` `invalid_request` などに分類して表示します。
- ネイティブアプリの履歴カレンダは「操作日」ではなく「動画の撮影日」を基準に集計します。
- 履歴カレンダは `.iphoto2youtube/history_calendar.db` に保存し、起動時はこの DB を直接読みます。
- 履歴カレンダのアップロード / 削除集計は、アップロード成功時、iPhone 削除時、手動補正時に即時更新します。
- 写真ライブラリアクセス許可の付与後は自動読み込みせず、ユーザーが `読み込む` を押したときだけ対象日付の動画を取得します。
- 写真画面の `Auto` は、確認ダイアログ表示後に、読み込み済み動画と左側の重要項目を前提条件として実行します。
- `Auto` は、数字だけのファイル名を持つ `*.mp4` を Vlog、`VID_` を Insta360、`HOVER_` を HoverX1 と判定し、該当カテゴリだけを順番に `Upload` します。Vlog の長さ条件はありません。
- `Auto` は Insta360 / HoverX1 の `Upload` 成功後に、該当動画を写真ライブラリから削除します。
- `Auto` 実行前にアップロード画面へ未処理動画が残っている場合は、中断してエラー表示します。

## 保存データ

- 履歴 DB: `.iphoto2youtube/upload_history.db`
- 履歴カレンダ DB: `.iphoto2youtube/history_calendar.db`
- 管理 DB: `.iphoto2youtube/management.db`
- CSV 台帳: `.iphoto2youtube/ledger.csv`
- 設定ファイル: `.iphoto2youtube/config.json`

保存される主な項目:

- YouTube 動画 ID / URL
- タイトル
- 撮影日時 / 時間帯 / OffsetTimeOriginal
- 場所 / 内容 / イベント名 / 参加者 / カメラ種別 / プレイリスト
- ファイルサイズ / 動画時間 / 解像度
- 説明欄 / タグ / アップロード日時 / 実行結果
- 実行サマリー / エラー概要

## バッチ実行マニフェスト例

```json
{
  "defaults": {
    "place": "砧公園",
    "event_name": "花見",
    "participants": ["Alice", "Bob"],
    "camera_model": "iPhone",
    "playlists": ["[散歩] 自宅_花見"],
    "playlist_privacy_status": "private"
  },
  "videos": [
    {
      "video": "./movie1.mov",
      "capture_datetime": "2026-04-07 14:32:10",
      "content": "花見"
    },
    {
      "video": "./movie2.mov",
      "capture_datetime": "2026-04-07 14:40:10",
      "content": "散歩"
    }
  ]
}
```

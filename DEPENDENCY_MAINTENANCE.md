# 依存ライブラリの更新

## 対象

Python CLIの実行時依存は `pyproject.toml` の3件のGoogle APIライブラリで管理する。Swiftネイティブアプリは現在、Swift Packageの外部依存を使用していない。

このリポジトリにはロックファイルがない。月次更新では `pyproject.toml` の下限を検証済みの安定版へ更新し、インストール時にはパッケージマネージャーに推移的依存の互換解決を委ねる。

## 月次手順

1. 未コミットの機能変更を整理し、`codex/dependencies-YYYY-MM` の専用ブランチを作成する。
2. `python3 -m pip index versions <package>` で各直接依存の非プレリリース安定版を確認し、メジャー更新はリリースノートを個別に確認する。
3. クリーンな仮想環境で `python3 -m pip install .` を実行して依存を解決する。
4. `python3 -m unittest discover -s tests -v`、`swift test`、`git diff --check` を実行する。YouTubeの認証・アップロード・書き込みは外部状態を変更するため、テスト用アカウントとデータを使う別途の手動確認とする。
5. `pyproject.toml` とこの記録を、機能変更とは別コミットで push する。

脆弱性通知を受けた場合は月次を待たず、影響範囲と修正版を確認して同じ検証を行う。GitHub Dependabot alertsも有効化する。

## 2026-09-09 点検・更新

- `google-api-python-client`: 2.170.0 → 2.200.0
- `google-auth-httplib2`: 0.2.0 → 0.4.2
- `google-auth-oauthlib`: 1.2.0 → 1.4.1
- 3件ともPyPIで確認した最新の非プレリリース安定版を下限として記録した。
- Swift Packageの外部依存とPythonのロックファイルは存在しないため、更新対象はなかった。
- Python 3.14.7のクリーンな仮想環境で、更新済み依存の解決・インストールに成功。YouTube APIサービスとCLI設定の単体テスト16件、およびSwiftのテスト・ビルドに成功。
- テスト用のアップロード日時を実行時刻基準に更新後、Python全40件の単体テストに成功。

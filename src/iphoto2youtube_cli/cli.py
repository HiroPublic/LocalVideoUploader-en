from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .app import Application, CommandResult
from .config import AppSettings, build_app_paths, load_app_settings, load_dotenv
from .exceptions import CliError, ValidationError, YouTubeApiError
from .media_info import format_duration, format_file_size, format_resolution
from .validators import build_video_metadata_input, build_video_metadata_input_from_mapping

PROGRESS_EVENT_PREFIX = "::progress::"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="iphoto2youtube",
        description="iPhoto/Photos 動画の YouTube 非公開アップロードを検証する Python CLI MVP",
    )
    parser.add_argument(
        "--support-dir",
        help="認証情報・SQLite・CSV を保存するディレクトリ。未指定時はローカル共有ディレクトリを使用します。",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    _build_auth_status_parser(subparsers)
    _build_auth_login_parser(subparsers)
    _build_auth_logout_parser(subparsers)
    _build_channel_parser(subparsers)
    _build_verify_parser(subparsers)
    _build_sync_upload_metadata_parser(subparsers)
    _build_delete_uploaded_video_parser(subparsers)
    _build_delete_local_history_parser(subparsers)
    _build_backfill_parser(subparsers)
    _build_runs_parser(subparsers)
    _build_history_parser(subparsers)
    _build_search_parser(subparsers)
    _build_render_metadata_parser(subparsers)
    _build_upload_parser(subparsers)
    _build_batch_upload_parser(subparsers)

    return parser


def _build_auth_status_parser(subparsers: argparse._SubParsersAction) -> None:
    subparsers.add_parser("auth-status", help="OAuth セッションの有無を確認します。")


def _build_auth_login_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("auth-login", help="Google OAuth ログインを開始します。")
    parser.add_argument("--expected-channel", help="このチャンネル名またはハンドルでログイン完了した場合のみトークンを採用します。")
    parser.add_argument("--expected-channel-id", help="このチャンネル ID でログイン完了した場合のみトークンを採用します。")


def _build_auth_logout_parser(subparsers: argparse._SubParsersAction) -> None:
    subparsers.add_parser("auth-logout", help="保存済み OAuth セッションを削除します。")


def _build_channel_parser(subparsers: argparse._SubParsersAction) -> None:
    subparsers.add_parser(
        "current-channel",
        help="現在の OAuth セッションでアップロードされるチャンネルを表示します。",
    )


def _build_verify_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "verify-upload",
        help="YouTube 側の動画メタデータとプレイリスト所属を検証します。",
    )
    parser.add_argument("--youtube-video-id", required=True, help="検証対象の YouTube 動画 ID")
    parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )


def _build_sync_upload_metadata_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "sync-upload-metadata",
        help="ローカル履歴に合わせて YouTube 側の動画メタデータを同期します。",
    )
    parser.add_argument("--youtube-video-id", required=True, help="同期対象の YouTube 動画 ID")
    parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )


def _build_delete_uploaded_video_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "delete-uploaded-video",
        help="YouTube 上の動画とローカル履歴を削除します。",
    )
    parser.add_argument("--youtube-video-id", required=True, help="削除対象の YouTube 動画 ID")
    parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )


def _build_delete_local_history_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "delete-local-history",
        help="ローカル履歴と管理 DB だけを削除します。",
    )
    parser.add_argument("--youtube-video-id", required=True, help="削除対象の YouTube 動画 ID")
    parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )


def _build_backfill_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "backfill",
        help="過去レコードのタイトル・メディア情報を補完し、CSV 台帳を再出力します。",
    )
    parser.add_argument(
        "--ledger-csv",
        help="CSV 台帳の出力先。未指定時は support-dir 配下の ledger.csv を使います。",
    )


def _build_runs_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "runs",
        help="CLI 実行サマリーを一覧または詳細表示します。",
    )
    run_subparsers = parser.add_subparsers(dest="runs_command", required=True)

    list_parser = run_subparsers.add_parser("list", help="実行サマリー一覧を表示します。")
    list_parser.add_argument("--limit", type=int, default=20, help="最大件数")
    list_parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )

    show_parser = run_subparsers.add_parser("show", help="実行サマリー詳細を表示します。")
    show_parser.add_argument("--id", type=int, required=True, help="execution_log の ID")


def _build_history_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "history",
        help="アップロード履歴を一覧または詳細表示します。",
    )
    history_subparsers = parser.add_subparsers(dest="history_command", required=True)

    list_parser = history_subparsers.add_parser("list", help="履歴一覧を表示します。")
    list_parser.add_argument("--limit", type=int, default=20, help="最大件数")
    list_parser.add_argument("--upload-status", help="upload_status で絞り込みます。")
    list_parser.add_argument("--query", help="ファイル名、タイトル、プレイリストなどで部分一致検索します。")
    list_parser.add_argument("--capture-date", help="撮影日で絞り込みます。例: 2026-04-07")
    list_parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )

    show_parser = history_subparsers.add_parser("show", help="履歴詳細を表示します。")
    show_parser.add_argument("--id", type=int, help="履歴 ID")
    show_parser.add_argument("--youtube-video-id", help="YouTube 動画 ID")


def _build_search_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "search-videos",
        help="管理 DB に保存した動画を検索します。",
    )
    parser.add_argument("--title-contains", help="タイトル部分一致")
    parser.add_argument("--place", help="場所部分一致")
    parser.add_argument("--event-name", help="イベント名部分一致")
    parser.add_argument("--camera-model", help="カメラ種別部分一致")
    parser.add_argument("--participant", help="参加者部分一致")
    parser.add_argument("--playlist", help="プレイリスト部分一致")
    parser.add_argument("--min-duration", type=float, help="最小動画時間（秒）")
    parser.add_argument("--max-duration", type=float, help="最大動画時間（秒）")
    parser.add_argument("--min-width", type=int, help="最小横幅")
    parser.add_argument("--min-height", type=int, help="最小縦幅")
    parser.add_argument("--min-file-size", type=int, help="最小ファイルサイズ（bytes）")
    parser.add_argument("--limit", type=int, default=20, help="最大件数")
    parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="検索結果の表示形式。既定値: table",
    )


def _add_metadata_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--video", required=True, help="ローカル動画ファイルのパス")
    parser.add_argument(
        "--capture-datetime",
        required=True,
        help="撮影日時。例: 2026-04-07 14:32:10",
    )
    parser.add_argument("--timezone", default="JST", help="時間帯。既定値: JST")
    parser.add_argument(
        "--offset-time-original",
        default="+09:00",
        help="OffsetTimeOriginal の値。既定値: +09:00",
    )
    parser.add_argument("--place", help="場所")
    parser.add_argument("--content", help="内容")
    parser.add_argument("--title", help="YouTube に設定するタイトル。未指定時は自動生成します。")
    parser.add_argument("--description", help="YouTube に設定する説明欄。未指定時は自動生成します。")
    parser.add_argument("--event-name", help="イベント名")
    parser.add_argument(
        "--participants",
        action="append",
        help="参加者。複数指定可、またはカンマ区切り。",
    )
    parser.add_argument("--camera-model", help="カメラ種別")
    parser.add_argument(
        "--playlists",
        action="append",
        help="プレイリスト名。複数指定可、またはカンマ区切り。",
    )
    parser.add_argument("--note", help="任意メモ")
    parser.add_argument("--library-name", default="Local Files", help="元ライブラリ名")
    parser.add_argument(
        "--capture-date-source",
        default="manual_input",
        help="基準日時ソース。既定値: manual_input",
    )
    parser.add_argument(
        "--original-capture-datetime",
        help="元の撮影日時。未指定時は撮影日時と同値として説明欄へ反映します。",
    )
    parser.add_argument(
        "--privacy-status",
        default=None,
        choices=["private", "unlisted", "public"],
        help="アップロード公開設定。MVP 既定値は private。",
    )
    parser.add_argument(
        "--playlist-privacy-status",
        default=None,
        choices=["private", "unlisted", "public"],
        help="未作成プレイリストを自動作成する際の公開設定。既定値: private",
    )


def _build_render_metadata_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "render-metadata",
        help="タイトル・説明欄・タグを生成して表示します。",
    )
    _add_metadata_arguments(parser)


def _build_upload_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "upload",
        help="YouTube へアップロードし、履歴 DB・管理 DB・CSV 台帳を更新します。",
    )
    _add_metadata_arguments(parser)
    parser.add_argument(
        "--ledger-csv",
        help="CSV 台帳の出力先。未指定時は support-dir 配下の ledger.csv を使います。",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="YouTube API を呼ばずにメタデータ生成と DB/CSV 更新のみ検証します。",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="アップロード前の確認を省略して続行します。",
    )
    parser.add_argument(
        "--expected-channel",
        help="このチャンネル名またはハンドルに一致する場合のみアップロードします。",
    )
    parser.add_argument(
        "--expected-channel-id",
        help="このチャンネル ID に一致する場合のみアップロードします。",
    )
    parser.add_argument(
        "--allow-duplicate",
        action="store_true",
        help="既存の成功済みアップロードが見つかってもスキップせず続行します。",
    )


def _build_batch_upload_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser(
        "batch-upload",
        help="JSON マニフェストに定義した複数動画を一括アップロードします。",
    )
    parser.add_argument("--manifest", required=True, help="一括アップロード用 JSON マニフェスト")
    parser.add_argument(
        "--ledger-csv",
        help="CSV 台帳の出力先。未指定時は support-dir 配下の ledger.csv を使います。",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="YouTube API を呼ばずにメタデータ生成と DB/CSV 更新のみ検証します。",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="一括アップロード前の確認を省略して続行します。",
    )
    parser.add_argument(
        "--expected-channel",
        help="このチャンネル名またはハンドルに一致する場合のみアップロードします。",
    )
    parser.add_argument(
        "--expected-channel-id",
        help="このチャンネル ID に一致する場合のみアップロードします。",
    )
    parser.add_argument(
        "--allow-duplicate",
        action="store_true",
        help="既存の成功済みアップロードが見つかってもスキップせず続行します。",
    )
    parser.add_argument(
        "--output",
        choices=["table", "json"],
        default="table",
        help="表示形式。既定値: table",
    )


def _build_application(args: argparse.Namespace) -> Application:
    paths = build_app_paths()
    if args.support_dir:
        support_dir = Path(args.support_dir).expanduser()
        paths = paths.__class__(
            support_dir=support_dir,
            credentials_file=support_dir / "client_secret.json",
            token_file=support_dir / "token.json",
            history_db=support_dir / "upload_history.db",
            management_db=support_dir / "management.db",
            ledger_csv=support_dir / "ledger.csv",
            settings_file=support_dir / "config.json",
        )
    settings = load_app_settings(paths)
    return Application(paths, settings=settings)


def main(argv: list[str] | None = None) -> int:
    load_dotenv()
    parser = build_parser()
    args = parser.parse_args(argv)
    app = _build_application(args)
    _apply_settings_defaults(args, app.settings)
    try:
        if args.command == "auth-status":
            result = app.auth_status()
        elif args.command == "auth-login":
            result = app.auth_login_with_expectation(
                expected_channel=args.expected_channel,
                expected_channel_id=args.expected_channel_id,
            )
        elif args.command == "auth-logout":
            result = app.auth_logout()
        elif args.command == "current-channel":
            channel = app.get_authenticated_channel()
            result = CommandResult(
                message="current_channel",
                payload={
                    "channel_id": channel.channel_id,
                    "channel_title": channel.title,
                    "channel_handle": channel.handle,
                },
            )
        elif args.command == "verify-upload":
            result = app.verify_upload(youtube_video_id=args.youtube_video_id)
        elif args.command == "sync-upload-metadata":
            result = app.sync_upload_metadata(youtube_video_id=args.youtube_video_id)
        elif args.command == "delete-uploaded-video":
            result = app.delete_uploaded_video(youtube_video_id=args.youtube_video_id)
        elif args.command == "delete-local-history":
            result = app.delete_local_history(youtube_video_id=args.youtube_video_id)
        elif args.command == "backfill":
            ledger_csv = Path(args.ledger_csv).expanduser() if args.ledger_csv else None
            result = app.backfill(ledger_csv_path=ledger_csv)
        elif args.command == "runs":
            if args.runs_command == "list":
                result = app.runs_list(limit=args.limit)
            elif args.runs_command == "show":
                result = app.runs_show(execution_id=args.id)
            else:
                parser.error(f"未対応 runs サブコマンドです: {args.runs_command}")
                return 2
        elif args.command == "history":
            if args.history_command == "list":
                result = app.history_list(
                    limit=args.limit,
                    upload_status=args.upload_status,
                    query_text=args.query,
                    capture_date=args.capture_date,
                )
            elif args.history_command == "show":
                if args.id is None and not args.youtube_video_id:
                    raise ValidationError("`history show` では --id または --youtube-video-id を指定してください。")
                result = app.history_show(history_id=args.id, youtube_video_id=args.youtube_video_id)
            else:
                parser.error(f"未対応 history サブコマンドです: {args.history_command}")
                return 2
        elif args.command == "search-videos":
            result = app.search_videos(
                title_contains=args.title_contains,
                place=args.place,
                event_name=args.event_name,
                camera_model=args.camera_model,
                participant=args.participant,
                playlist=args.playlist,
                min_duration=args.min_duration,
                max_duration=args.max_duration,
                min_width=args.min_width,
                min_height=args.min_height,
                min_file_size=args.min_file_size,
                limit=args.limit,
            )
        elif args.command == "render-metadata":
            metadata = build_video_metadata_input(args)
            result = app.render_metadata(metadata)
        elif args.command == "upload":
            metadata = build_video_metadata_input(args)
            duplicate = None if args.allow_duplicate else app.find_duplicate(metadata)
            if not args.dry_run and not duplicate:
                channel = app.get_authenticated_channel()
                _validate_expected_channel(args, channel)
                preview = app.build_upload_preview(metadata)
                _confirm_upload_target(channel, preview, assume_yes=args.yes)
            ledger_csv = Path(args.ledger_csv).expanduser() if args.ledger_csv else None
            result = app.upload(
                metadata,
                dry_run=args.dry_run,
                ledger_csv_path=ledger_csv,
                allow_duplicate=args.allow_duplicate,
            )
        elif args.command == "batch-upload":
            manifest_path = Path(args.manifest).expanduser()
            items = _load_batch_manifest(manifest_path, app.settings)
            if not args.dry_run:
                channel = app.get_authenticated_channel()
                _validate_expected_channel(args, channel)
                _confirm_batch_upload_target(channel, items, assume_yes=args.yes)
            ledger_csv = Path(args.ledger_csv).expanduser() if args.ledger_csv else None
            result = app.batch_upload(
                items,
                dry_run=args.dry_run,
                ledger_csv_path=ledger_csv,
                allow_duplicate=args.allow_duplicate,
                progress_callback=_emit_progress_event,
            )
        else:
            parser.error(f"未対応コマンドです: {args.command}")
            return 2
    except CliError as exc:
        if isinstance(exc, YouTubeApiError):
            payload = {
                "message": str(exc),
                "operation": exc.operation,
                "category": exc.category,
                "retryable": exc.retryable,
                "status_code": exc.status_code,
                "reason": exc.reason,
            }
            print(json.dumps({"message": "youtube_api_error", "payload": payload}, ensure_ascii=False, indent=2), file=sys.stderr)
            return 1
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.command == "search-videos" and args.output == "table":
        _print_search_results_table(result.payload or {})
    elif args.command == "verify-upload" and args.output == "table":
        _print_verify_upload_table(result.payload or {})
    elif args.command == "sync-upload-metadata" and args.output == "table":
        _print_sync_upload_metadata_table(result.payload or {})
    elif args.command == "delete-uploaded-video" and args.output == "table":
        _print_delete_uploaded_video_table(result.payload or {})
    elif args.command == "delete-local-history" and args.output == "table":
        _print_delete_local_history_table(result.payload or {})
    elif args.command == "runs" and getattr(args, "runs_command", None) == "list" and args.output == "table":
        _print_runs_results_table(result.payload or {})
    elif args.command == "history" and getattr(args, "history_command", None) == "list" and args.output == "table":
        _print_history_results_table(result.payload or {})
    elif args.command == "upload":
        _print_upload_result(result)
    elif args.command == "batch-upload" and args.output == "table":
        _print_batch_upload_result(result)
    else:
        print(json.dumps({"message": result.message, "payload": result.payload or {}}, ensure_ascii=False, indent=2))
    return 0


def _emit_progress_event(payload: dict[str, object]) -> None:
    print(
        f"{PROGRESS_EVENT_PREFIX}{json.dumps(payload, ensure_ascii=False)}",
        file=sys.stderr,
        flush=True,
    )


def _apply_settings_defaults(args: argparse.Namespace, settings: AppSettings) -> None:
    if getattr(args, "expected_channel", None) in {None, ""} and settings.expected_channel:
        args.expected_channel = settings.expected_channel
    if getattr(args, "expected_channel_id", None) in {None, ""} and settings.expected_channel_id:
        args.expected_channel_id = settings.expected_channel_id

    if hasattr(args, "privacy_status") and args.privacy_status is None:
        args.privacy_status = settings.default_privacy_status
    if hasattr(args, "playlist_privacy_status") and args.playlist_privacy_status is None:
        args.playlist_privacy_status = settings.default_playlist_privacy_status
    if hasattr(args, "timezone") and (args.timezone == "JST" or args.timezone in {None, ""}):
        args.timezone = settings.default_timezone
    if hasattr(args, "offset_time_original") and (args.offset_time_original == "+09:00" or args.offset_time_original in {None, ""}):
        args.offset_time_original = settings.default_offset_time_original
    if hasattr(args, "library_name") and (args.library_name == "Local Files" or args.library_name in {None, ""}):
        args.library_name = settings.default_library_name
    if hasattr(args, "capture_date_source") and (
        args.capture_date_source == "manual_input" or args.capture_date_source in {None, ""}
    ):
        args.capture_date_source = settings.default_capture_date_source


def _validate_expected_channel(args: argparse.Namespace, channel) -> None:
    expected_channel = (args.expected_channel or "").strip()
    expected_channel_id = (args.expected_channel_id or "").strip()
    if expected_channel:
        candidates = {channel.title.casefold(), channel.handle.casefold()}
        if expected_channel.casefold() not in candidates:
            raise ValidationError(
                f"認証先チャンネルが期待値と一致しません。現在: {channel.title} ({channel.handle or 'handleなし'})"
            )
    if expected_channel_id and expected_channel_id != channel.channel_id:
        raise ValidationError(
            f"認証先チャンネル ID が期待値と一致しません。現在: {channel.channel_id}"
        )


def _confirm_upload_target(channel, preview: dict[str, str], assume_yes: bool) -> None:
    if assume_yes:
        return
    if not sys.stdin.isatty():
        raise ValidationError(
            "実アップロード前の確認が必要です。`--yes` を付けるか対話端末で実行してください。"
        )
    print("=== Upload Preview ===")
    print(
        f"Channel: {channel.title}"
        f"{f' ({channel.handle})' if channel.handle else ''} [{channel.channel_id}]"
    )
    print(f"Video: {preview['video_path']}")
    print(f"File Size: {preview['file_size_human']} ({preview['file_size_bytes']} bytes)")
    print(f"Capture Datetime: {preview['capture_datetime']}")
    print(f"Duration: {preview['duration']}")
    print(f"Resolution: {preview['resolution']}")
    print(f"Privacy: {preview['privacy_status']}")
    print(f"Playlist Privacy: {preview['playlist_privacy_status']}")
    print(f"Title: {preview['title']}")
    print(f"Playlists: {preview['playlists']}")
    print(f"Tags: {preview['tags']}")
    print("Description:")
    print(preview["description"])
    print("=== End Preview ===")
    prompt = "この内容でアップロードを続行しますか？ [y/N]: "
    answer = input(prompt).strip().lower()
    if answer not in {"y", "yes"}:
        raise ValidationError("アップロードを中止しました。")


def _confirm_batch_upload_target(channel, items: list, assume_yes: bool) -> None:
    if assume_yes:
        return
    if not sys.stdin.isatty():
        raise ValidationError(
            "一括アップロード前の確認が必要です。`--yes` を付けるか対話端末で実行してください。"
        )
    print("=== Batch Upload Preview ===")
    print(
        f"Channel: {channel.title}"
        f"{f' ({channel.handle})' if channel.handle else ''} [{channel.channel_id}]"
    )
    print(f"Videos: {len(items)}")
    for index, item in enumerate(items, start=1):
        print(
            f"{index}. {item.capture_datetime.strftime('%Y-%m-%d %H:%M:%S')} "
            f"{item.video_path} -> {item.place or '場所未設定'} / {item.content or '内容未設定'}"
        )
    print("=== End Preview ===")
    answer = input("この内容で一括アップロードを続行しますか？ [y/N]: ").strip().lower()
    if answer not in {"y", "yes"}:
        raise ValidationError("一括アップロードを中止しました。")


def _print_upload_result(result: CommandResult) -> None:
    payload = result.payload or {}
    summary = payload.get("summary", {}) if isinstance(payload, dict) else {}
    print(f"Result: {result.message}")
    if isinstance(summary, dict):
        print(
            "Summary: "
            f"uploaded={summary.get('uploaded_count', 0)} "
            f"skipped={summary.get('skipped_count', 0)} "
            f"failed={summary.get('failed_count', 0)}"
        )
        if summary.get("error_summary"):
            print(f"Error Summary: {summary.get('error_summary')}")
    if isinstance(payload, dict):
        if payload.get("title"):
            print(f"Title: {payload['title']}")
        if payload.get("youtube_video_id"):
            print(f"Video ID: {payload['youtube_video_id']}")
        if payload.get("youtube_video_url"):
            print(f"Video URL: {payload['youtube_video_url']}")
        if payload.get("reason"):
            print(f"Reason: {payload['reason']}")
        if payload.get("csv_path"):
            print(f"CSV: {payload['csv_path']}")


def _print_batch_upload_result(result: CommandResult) -> None:
    payload = result.payload or {}
    summary = payload.get("summary", {}) if isinstance(payload, dict) else {}
    print(f"Result: {result.message}")
    if isinstance(summary, dict):
        print(
            "Summary: "
            f"total={summary.get('total', 0)} "
            f"uploaded={summary.get('uploaded_count', 0)} "
            f"skipped={summary.get('skipped_count', 0)} "
            f"failed={summary.get('failed_count', 0)}"
        )
    results = payload.get("results", []) if isinstance(payload, dict) else []
    if isinstance(results, list) and results:
        for item in results:
            if not isinstance(item, dict):
                continue
            line = f"- {item.get('status', '')}: {item.get('video_path', '')}"
            if item.get("youtube_video_id"):
                line += f" -> {item.get('youtube_video_id', '')}"
            if item.get("reason"):
                line += f" ({item.get('reason', '')})"
            print(line)
    if isinstance(payload, dict) and payload.get("csv_path"):
        print(f"CSV: {payload['csv_path']}")


def _load_batch_manifest(manifest_path: Path, settings: AppSettings) -> list:
    if not manifest_path.exists():
        raise ValidationError(f"マニフェストが見つかりません: {manifest_path}")
    try:
        raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValidationError(f"マニフェスト JSON の形式が不正です: {manifest_path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ValidationError("マニフェストは JSON object である必要があります。")
    defaults = raw.get("defaults", {})
    videos = raw.get("videos", [])
    if defaults is None:
        defaults = {}
    if not isinstance(defaults, dict):
        raise ValidationError("マニフェストの defaults は object である必要があります。")
    if not isinstance(videos, list) or not videos:
        raise ValidationError("マニフェストの videos には 1 件以上の配列が必要です。")

    merged_defaults = {
        "timezone": settings.default_timezone,
        "offset_time_original": settings.default_offset_time_original,
        "library_name": settings.default_library_name,
        "capture_date_source": settings.default_capture_date_source,
        "privacy_status": settings.default_privacy_status,
        "playlist_privacy_status": settings.default_playlist_privacy_status,
        **defaults,
    }

    items = []
    for index, video in enumerate(videos, start=1):
        if not isinstance(video, dict):
            raise ValidationError(f"videos[{index}] は object である必要があります。")
        merged = {**merged_defaults, **video}
        if "video" not in merged or "capture_datetime" not in merged:
            raise ValidationError(f"videos[{index}] には video と capture_datetime が必要です。")
        items.append(build_video_metadata_input_from_mapping(merged))
    return items


def _print_search_results_table(payload: dict[str, object]) -> None:
    results = payload.get("results", [])
    if not isinstance(results, list) or not results:
        print("No results.")
        return

    headers = ["video_id", "title", "capture", "media", "place", "event", "camera"]
    rows: list[list[str]] = []
    for item in results:
        if not isinstance(item, dict):
            continue
        media = " / ".join(
            [
                format_duration(item.get("duration_seconds")),
                format_resolution(item.get("width"), item.get("height")),
                format_file_size(int(item.get("file_size_bytes") or 0)) if item.get("file_size_bytes") else "不明",
            ]
        )
        rows.append(
            [
                str(item.get("youtube_video_id", "")),
                str(item.get("title") or ""),
                str(item.get("effective_capture_date") or ""),
                media,
                str(item.get("place") or ""),
                str(item.get("event_name") or ""),
                str(item.get("camera_model") or ""),
            ]
        )

    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def render_row(values: list[str]) -> str:
        return " | ".join(value.ljust(widths[index]) for index, value in enumerate(values))

    print(render_row(headers))
    print("-+-".join("-" * width for width in widths))
    for row in rows:
        print(render_row(row))


def _print_history_results_table(payload: dict[str, object]) -> None:
    results = payload.get("results", [])
    if not isinstance(results, list) or not results:
        print("No history.")
        return

    headers = ["id", "status", "uploaded_at", "video_id", "title", "media", "path"]
    rows: list[list[str]] = []
    for item in results:
        if not isinstance(item, dict):
            continue
        media = " / ".join(
            [
                format_duration(item.get("duration_seconds")),
                format_resolution(item.get("width"), item.get("height")),
                format_file_size(int(item.get("file_size_bytes") or 0)) if item.get("file_size_bytes") else "不明",
            ]
        )
        rows.append(
            [
                str(item.get("id") or ""),
                str(item.get("upload_status") or ""),
                str(item.get("uploaded_at") or ""),
                str(item.get("youtube_video_id") or ""),
                str(item.get("title") or ""),
                media,
                str(item.get("video_path") or ""),
            ]
        )

    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def render_row(values: list[str]) -> str:
        return " | ".join(value.ljust(widths[index]) for index, value in enumerate(values))

    print(render_row(headers))
    print("-+-".join("-" * width for width in widths))
    for row in rows:
        print(render_row(row))


def _print_runs_results_table(payload: dict[str, object]) -> None:
    results = payload.get("results", [])
    if not isinstance(results, list) or not results:
        print("No runs.")
        return

    headers = ["id", "started_at", "uploaded", "skipped", "failed", "target_date", "error_summary"]
    rows: list[list[str]] = []
    for item in results:
        if not isinstance(item, dict):
            continue
        rows.append(
            [
                str(item.get("id") or ""),
                str(item.get("started_at") or ""),
                str(item.get("uploaded_count", "")),
                str(item.get("skipped_count", "")),
                str(item.get("failed_count", "")),
                str(item.get("target_date") or ""),
                str(item.get("error_summary") or ""),
            ]
        )

    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def render_row(values: list[str]) -> str:
        return " | ".join(value.ljust(widths[index]) for index, value in enumerate(values))

    print(render_row(headers))
    print("-+-".join("-" * width for width in widths))
    for row in rows:
        print(render_row(row))


def _print_verify_upload_table(payload: dict[str, object]) -> None:
    remote = payload.get("remote", {})
    if not isinstance(remote, dict) or not remote:
        print("No remote data.")
        return
    print("Remote:")
    print(f"  video_id: {remote.get('youtube_video_id', '')}")
    print(f"  channel: {remote.get('channel_title', '')} [{remote.get('channel_id', '')}]")
    print(f"  title: {remote.get('title', '')}")
    print(f"  privacy: {remote.get('privacy_status', '')}")
    print(f"  upload_status: {remote.get('upload_status', '')}")
    print(f"  processing_status: {remote.get('processing_status', '')}")
    resolution = remote.get("resolution", {}) or {}
    print(f"  resolution: {resolution.get('width_pixels', '')}x{resolution.get('height_pixels', '')}")
    print(f"  file_size_bytes: {remote.get('file_size_bytes', '')}")
    print(f"  playlists: {', '.join(item.get('title', '') for item in (remote.get('playlists') or []))}")
    print(f"  tags: {', '.join(remote.get('tags') or [])}")

    comparisons = payload.get("comparisons", [])
    if isinstance(comparisons, list) and comparisons:
        print("")
        print("Comparison:")
        headers = ["field", "status", "local", "remote"]
        rows: list[list[str]] = []
        for item in comparisons:
            if not isinstance(item, dict):
                continue
            rows.append(
                [
                    str(item.get("field") or ""),
                    str(item.get("status") or ""),
                    str(item.get("local") or ""),
                    str(item.get("remote") or ""),
                ]
            )
        widths = [len(h) for h in headers]
        for row in rows:
            for i, value in enumerate(row):
                widths[i] = max(widths[i], len(value))

        def render_row(values: list[str]) -> str:
            return " | ".join(value.ljust(widths[i]) for i, value in enumerate(values))

        print(render_row(headers))
        print("-+-".join("-" * width for width in widths))
        for row in rows:
            print(render_row(row))


def _print_sync_upload_metadata_table(payload: dict[str, object]) -> None:
    summary = payload.get("sync_summary", {})
    if isinstance(summary, dict):
        print("Sync:")
        print(f"  video_id: {summary.get('video_id', '')}")
        print(f"  updated_fields: {', '.join(summary.get('updated_fields') or [])}")
        print(f"  added_playlists: {', '.join(summary.get('added_playlists') or [])}")
        print(f"  removed_playlists: {', '.join(summary.get('removed_playlists') or [])}")
        print("")
    _print_verify_upload_table(payload)


def _print_delete_uploaded_video_table(payload: dict[str, object]) -> None:
    print("Delete:")
    print(f"  youtube_video_id: {payload.get('youtube_video_id', '')}")
    print(f"  remote_deleted: {payload.get('remote_deleted', False)}")
    print(f"  remote_missing: {payload.get('remote_missing', False)}")
    print(f"  remote_skipped: {payload.get('remote_skipped', False)}")
    print(f"  history_deleted: {payload.get('history_deleted', 0)}")
    print(f"  management_deleted: {payload.get('management_deleted', 0)}")
    print(f"  csv_path: {payload.get('csv_path', '')}")


def _print_delete_local_history_table(payload: dict[str, object]) -> None:
    print("Delete Local History:")
    print(f"  youtube_video_id: {payload.get('youtube_video_id', '')}")
    print(f"  history_deleted: {payload.get('history_deleted', 0)}")
    print(f"  management_deleted: {payload.get('management_deleted', 0)}")
    print(f"  csv_path: {payload.get('csv_path', '')}")

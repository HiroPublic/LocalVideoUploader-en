from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import inspect
import json
from pathlib import Path
import time

from .config import AppPaths, AppSettings
from .media_info import format_duration, format_file_size, format_resolution
from .metadata import compose_metadata
from .exceptions import AuthError, CliError, ValidationError, YouTubeApiError
from .models import ChannelInfo, UploadAttemptResult, UploadResult, UploadSummary, VideoMetadataInput
from .services.auth import GoogleOAuthService
from .services.youtube import YouTubeUploadService, fetch_authenticated_channel, fetch_video_verification
from .storage import LedgerExportService, UploadHistoryRepository, VideoManagementRepository


@dataclass(slots=True)
class CommandResult:
    message: str
    payload: dict[str, object] | None = None


class Application:
    def __init__(self, paths: AppPaths, settings: AppSettings | None = None) -> None:
        self.paths = paths
        self.settings = settings or AppSettings()
        self.auth_service = GoogleOAuthService(paths.credentials_file, paths.token_file)
        self.history_repo = UploadHistoryRepository(paths.history_db)
        self.management_repo = VideoManagementRepository(paths.management_db)
        self.ledger_service = LedgerExportService()

    def initialize(self) -> None:
        self.paths.support_dir.mkdir(parents=True, exist_ok=True)
        self.history_repo.initialize()
        self.management_repo.initialize()
        cleanup = self.history_repo.purge_expired_api_data()
        management_deleted = self.management_repo.purge_expired_api_data()
        if cleanup["history_deleted"] > 0 or management_deleted > 0:
            records = self.management_repo.fetch_all_for_ledger()
            self.ledger_service.export_csv(records, self.paths.ledger_csv)

    def auth_status(self) -> CommandResult:
        self.initialize()
        authenticated = self.auth_service.is_authenticated()
        token_path = self.paths.token_file if self.paths.token_file.exists() else None
        message = "authenticated" if authenticated else "unauthenticated"
        payload = {
            "status": message,
            "token_file": str(token_path) if token_path else "",
            "credentials_file": str(self.paths.credentials_file),
            "youtube_api_quota": self.history_repo.get_daily_api_quota_usage(
                daily_limit=self.settings.youtube_api_daily_quota_limit
            ),
        }
        return CommandResult(message=message, payload=payload)

    def auth_login(self) -> CommandResult:
        self.initialize()
        self.auth_service.login()
        channel = self.get_authenticated_channel()
        self._validate_channel_expectation(
            channel,
            expected_channel=None,
            expected_channel_id=None,
        )
        return CommandResult(
            message="authenticated",
            payload={
                "token_file": str(self.paths.token_file),
                "channel_id": channel.channel_id,
                "channel_title": channel.title,
                "channel_handle": channel.handle,
            },
        )

    def auth_logout(self) -> CommandResult:
        self.initialize()
        self.auth_service.logout()
        return CommandResult(message="signed_out")

    def get_authenticated_channel(self) -> ChannelInfo:
        self.initialize()
        credentials = self.auth_service.load_credentials()
        return self._call_with_optional_quota_logger(
            fetch_authenticated_channel,
            credentials,
        )

    def find_duplicate(self, metadata: VideoMetadataInput) -> dict[str, str] | None:
        self.initialize()
        return self.history_repo.find_duplicate(metadata)

    def render_metadata(self, metadata: VideoMetadataInput) -> CommandResult:
        self.initialize()
        composed = self._compose_metadata_for_upload(metadata)
        return CommandResult(
            message="metadata_rendered",
            payload={
                "title": composed.title,
                "description": composed.description,
                "tags": ", ".join(composed.tags),
                "playlists": ", ".join(composed.playlists),
            },
        )

    def upload(
        self,
        metadata: VideoMetadataInput,
        dry_run: bool = False,
        ledger_csv_path: Path | None = None,
        allow_duplicate: bool = False,
    ) -> CommandResult:
        self.initialize()
        attempt = self.perform_upload(
            metadata,
            dry_run=dry_run,
            ledger_csv_path=ledger_csv_path,
            allow_duplicate=allow_duplicate,
        )
        payload: dict[str, object] = {
            "summary": self._summary_to_payload(attempt.summary),
            "history_db": str(self.paths.history_db),
            "management_db": str(self.paths.management_db),
            "csv_path": str(ledger_csv_path or self.paths.ledger_csv),
        }
        if attempt.status == "skipped_duplicate":
            duplicate = self.history_repo.find_duplicate(metadata) or {}
            payload.update(
                {
                    "title": attempt.title or duplicate.get("title", ""),
                    "youtube_video_id": duplicate.get("youtube_video_id", ""),
                    "youtube_video_url": duplicate.get("youtube_video_url", ""),
                    "reason": attempt.reason,
                }
            )
            return CommandResult(message=attempt.status, payload=payload)
        if attempt.upload_result:
            payload.update(
                {
                    "title": attempt.title,
                    "youtube_video_id": attempt.upload_result.youtube_video_id,
                    "youtube_video_url": attempt.upload_result.youtube_video_url,
                }
            )
        return CommandResult(message=attempt.status, payload=payload)

    def perform_upload(
        self,
        metadata: VideoMetadataInput,
        *,
        dry_run: bool = False,
        ledger_csv_path: Path | None = None,
        allow_duplicate: bool = False,
    ) -> UploadAttemptResult:
        self.initialize()
        started_at = datetime.now()
        duplicate = None if allow_duplicate else self.history_repo.find_duplicate(metadata)
        if duplicate:
            summary = UploadSummary(
                started_at=started_at,
                finished_at=datetime.now(),
                uploaded_count=0,
                skipped_count=1,
                failed_count=0,
                error_summary="duplicate_skip",
            )
            self.history_repo.save_execution_log(summary, metadata.capture_datetime.strftime("%Y-%m-%d"))
            return UploadAttemptResult(
                upload_result=None,
                summary=summary,
                status="skipped_duplicate",
                reason="同一動画の成功済みアップロード履歴があるためスキップしました。",
                title=str(duplicate.get("title") or ""),
            )

        composed = self._compose_metadata_for_upload(metadata, uploaded_at=started_at)
        csv_path = ledger_csv_path or self.paths.ledger_csv
        try:
            if dry_run:
                result = UploadResult(
                    success=True,
                    youtube_video_id="DRYRUN",
                    youtube_video_url="https://www.youtube.com/watch?v=DRYRUN",
                    uploaded_at=started_at,
                    privacy_status=metadata.privacy_status,
                    upload_status="dry_run",
                )
            else:
                credentials = self.auth_service.load_credentials()
                youtube_service = self._build_youtube_service(credentials)
                result = youtube_service.upload_video(metadata, composed)

            self.history_repo.save_upload_result(metadata, composed, result)
            self.management_repo.upsert_video(metadata, composed, result)
            records = self.management_repo.fetch_all_for_ledger()
            self.ledger_service.export_csv(records, csv_path)
            summary = UploadSummary(
                started_at=started_at,
                finished_at=datetime.now(),
                uploaded_count=1,
                skipped_count=0,
                failed_count=0,
            )
            self.history_repo.save_execution_log(summary, metadata.capture_datetime.strftime("%Y-%m-%d"))
            return UploadAttemptResult(
                upload_result=result,
                summary=summary,
                status="dry_run" if dry_run else "uploaded",
                title=composed.title,
            )
        except CliError as exc:
            summary = UploadSummary(
                started_at=started_at,
                finished_at=datetime.now(),
                uploaded_count=0,
                skipped_count=0,
                failed_count=1,
                error_summary=str(exc),
            )
            self.history_repo.save_execution_log(summary, metadata.capture_datetime.strftime("%Y-%m-%d"))
            raise

    def build_upload_preview(self, metadata: VideoMetadataInput) -> dict[str, str]:
        self.initialize()
        composed = self._compose_metadata_for_upload(metadata)
        return {
            "video_path": str(metadata.video_path.resolve()),
            "file_size_bytes": str(metadata.file_size_bytes),
            "file_size_human": format_file_size(metadata.file_size_bytes),
            "capture_datetime": metadata.capture_datetime.isoformat(sep=" "),
            "duration": format_duration(metadata.duration_seconds),
            "resolution": format_resolution(metadata.width, metadata.height),
            "privacy_status": metadata.privacy_status,
            "playlist_privacy_status": metadata.playlist_privacy_status,
            "title": composed.title,
            "description": composed.description,
            "tags": ", ".join(composed.tags),
            "playlists": ", ".join(composed.playlists) if composed.playlists else "(なし)",
        }

    def _compose_metadata_for_upload(
        self,
        metadata: VideoMetadataInput,
        uploaded_at: datetime | None = None,
    ):
        if metadata.custom_title:
            return compose_metadata(metadata, uploaded_at=uploaded_at)
        title_probe = compose_metadata(metadata)
        collision_index = self.history_repo.next_collision_index(title_probe.title_base)
        return compose_metadata(metadata, collision_index=collision_index, uploaded_at=uploaded_at)

    def search_videos(
        self,
        *,
        title_contains: str | None = None,
        place: str | None = None,
        event_name: str | None = None,
        camera_model: str | None = None,
        participant: str | None = None,
        playlist: str | None = None,
        min_duration: float | None = None,
        max_duration: float | None = None,
        min_width: int | None = None,
        min_height: int | None = None,
        min_file_size: int | None = None,
        limit: int = 20,
    ) -> CommandResult:
        self.initialize()
        rows = self.management_repo.search_videos(
            title_contains=title_contains,
            place=place,
            event_name=event_name,
            camera_model=camera_model,
            participant=participant,
            playlist=playlist,
            min_duration=min_duration,
            max_duration=max_duration,
            min_width=min_width,
            min_height=min_height,
            min_file_size=min_file_size,
            limit=limit,
        )
        return CommandResult(
            message="search_results",
            payload={
                "count": str(len(rows)),
                "results": rows,
            },
        )

    def backfill(self, ledger_csv_path: Path | None = None) -> CommandResult:
        self.initialize()
        history_stats = self.history_repo.backfill_media_info()
        history_records = self.history_repo.latest_successful_records()
        management_updated = self.management_repo.backfill_from_history(history_records)
        csv_path = ledger_csv_path or self.paths.ledger_csv
        records = self.management_repo.fetch_all_for_ledger()
        self.ledger_service.export_csv(records, csv_path)
        return CommandResult(
            message="backfill_completed",
            payload={
                "history_scanned": str(history_stats["scanned"]),
                "history_updated": str(history_stats["updated"]),
                "missing_files": str(history_stats["missing_files"]),
                "management_updated": str(management_updated),
                "csv_path": str(csv_path),
            },
        )

    def batch_upload(
        self,
        items: list[VideoMetadataInput],
        *,
        dry_run: bool = False,
        ledger_csv_path: Path | None = None,
        allow_duplicate: bool = False,
    ) -> CommandResult:
        self.initialize()
        uploaded_count = 0
        skipped_count = 0
        failed_count = 0
        results: list[dict[str, object]] = []
        for index, metadata in enumerate(items):
            try:
                attempt = self.perform_upload(
                    metadata,
                    dry_run=dry_run,
                    ledger_csv_path=ledger_csv_path,
                    allow_duplicate=allow_duplicate,
                )
                if attempt.status == "skipped_duplicate":
                    skipped_count += 1
                else:
                    uploaded_count += 1
                results.append(
                    {
                        "video_path": str(metadata.video_path),
                        "status": attempt.status,
                        "title": attempt.title,
                        "youtube_video_id": attempt.upload_result.youtube_video_id if attempt.upload_result else "",
                        "youtube_video_url": attempt.upload_result.youtube_video_url if attempt.upload_result else "",
                        "reason": attempt.reason,
                    }
                )
            except CliError as exc:
                failed_count += 1
                results.append(
                    {
                        "video_path": str(metadata.video_path),
                        "status": "failed",
                        "title": "",
                        "youtube_video_id": "",
                        "youtube_video_url": "",
                        "reason": str(exc),
                    }
                )
                if self._should_abort_batch_after_error(exc):
                    remaining = items[index + 1 :]
                    failed_count += len(remaining)
                    for pending in remaining:
                        results.append(
                            {
                                "video_path": str(pending.video_path),
                                "status": "failed",
                                "title": "",
                                "youtube_video_id": "",
                                "youtube_video_url": "",
                                "reason": f"前の動画で続行不能なエラーが発生したため未実行: {exc}",
                            }
                        )
                    break

        return CommandResult(
            message="batch_completed",
            payload={
                "summary": {
                    "total": len(items),
                    "uploaded_count": uploaded_count,
                    "skipped_count": skipped_count,
                    "failed_count": failed_count,
                },
                "results": results,
                "csv_path": str(ledger_csv_path or self.paths.ledger_csv),
            },
        )

    @staticmethod
    def _should_abort_batch_after_error(exc: CliError) -> bool:
        if not isinstance(exc, YouTubeApiError):
            return False
        return exc.category in {"quota", "rate_limit", "upload_limit", "auth", "permission"}

    def history_list(
        self,
        *,
        limit: int = 20,
        upload_status: str | None = None,
        query_text: str | None = None,
        capture_date: str | None = None,
    ) -> CommandResult:
        self.initialize()
        rows = self.history_repo.list_history(
            limit=limit,
            upload_status=upload_status,
            query_text=query_text,
            capture_date=capture_date,
        )
        return CommandResult(
            message="history_list",
            payload={
                "count": str(len(rows)),
                "results": rows,
            },
        )

    def history_show(
        self,
        *,
        history_id: int | None = None,
        youtube_video_id: str | None = None,
    ) -> CommandResult:
        self.initialize()
        record = self.history_repo.get_history_record(
            history_id=history_id,
            youtube_video_id=youtube_video_id,
        )
        return CommandResult(
            message="history_record",
            payload={"record": record or {}},
        )

    def delete_uploaded_video(
        self,
        *,
        youtube_video_id: str,
    ) -> CommandResult:
        self.initialize()
        remote_deleted = False
        remote_missing = False
        remote_skipped = youtube_video_id in {"", "DRYRUN"}
        if not remote_skipped:
            try:
                credentials = self.auth_service.load_credentials()
            except AuthError as exc:
                raise ValidationError(str(exc)) from exc
            youtube_service = self._build_youtube_service(credentials)
            try:
                youtube_service.delete_video(youtube_video_id)
                remote_deleted = True
            except YouTubeApiError as exc:
                if exc.category == "permission":
                    raise ValidationError(
                        "YouTube 側の削除権限がありません。`認証状態を更新` の後に `auth-login` をやり直すか、"
                        "その動画をアップロードしたチャンネルで認証してください。"
                    ) from exc
                if exc.category == "not_found":
                    raise ValidationError(
                        "YouTube 側に削除対象の動画が見つかりませんでした。履歴は削除していません。"
                        "チャンネル違い、手動削除済み、または履歴上の Video ID 不整合の可能性があります。"
                    ) from exc
                if exc.category != "not_found":
                    raise

        history_deleted = self.history_repo.delete_by_youtube_video_id(youtube_video_id)
        management_deleted = self.management_repo.delete_by_youtube_video_id(youtube_video_id)
        records = self.management_repo.fetch_all_for_ledger()
        self.ledger_service.export_csv(records, self.paths.ledger_csv)
        return CommandResult(
            message="uploaded_video_deleted",
            payload={
                "youtube_video_id": youtube_video_id,
                "remote_deleted": remote_deleted,
                "remote_missing": remote_missing,
                "remote_skipped": remote_skipped,
                "history_deleted": history_deleted,
                "management_deleted": management_deleted,
                "csv_path": str(self.paths.ledger_csv),
            },
        )

    def delete_local_history(
        self,
        *,
        youtube_video_id: str,
    ) -> CommandResult:
        self.initialize()
        history_deleted = self.history_repo.delete_by_youtube_video_id(youtube_video_id)
        management_deleted = self.management_repo.delete_by_youtube_video_id(youtube_video_id)
        records = self.management_repo.fetch_all_for_ledger()
        self.ledger_service.export_csv(records, self.paths.ledger_csv)
        return CommandResult(
            message="local_history_deleted",
            payload={
                "youtube_video_id": youtube_video_id,
                "history_deleted": history_deleted,
                "management_deleted": management_deleted,
                "csv_path": str(self.paths.ledger_csv),
            },
        )

    def runs_list(self, *, limit: int = 20) -> CommandResult:
        self.initialize()
        rows = self.history_repo.list_execution_logs(limit=limit)
        return CommandResult(
            message="runs_list",
            payload={"count": str(len(rows)), "results": rows},
        )

    def runs_show(self, *, execution_id: int) -> CommandResult:
        self.initialize()
        record = self.history_repo.get_execution_log(execution_id=execution_id)
        return CommandResult(
            message="run_record",
            payload={"record": record or {}},
        )

    def verify_upload(
        self,
        *,
        youtube_video_id: str,
    ) -> CommandResult:
        self.initialize()
        credentials = self.auth_service.load_credentials()
        remote = self._call_with_optional_quota_logger(
            fetch_video_verification,
            credentials,
            youtube_video_id,
        )
        local_record = self.history_repo.get_history_record(youtube_video_id=youtube_video_id)
        comparisons = self._compare_local_and_remote(local_record, remote)
        return CommandResult(
            message="verify_upload",
            payload={
                "remote": remote,
                "local_history": local_record or {},
                "comparisons": comparisons,
            },
        )

    def sync_upload_metadata(
        self,
        *,
        youtube_video_id: str,
    ) -> CommandResult:
        self.initialize()
        local_record = self.history_repo.get_history_record(youtube_video_id=youtube_video_id)
        if not local_record:
            raise ValidationError("ローカル履歴が見つからないため、同期できません。")

        credentials = self.auth_service.load_credentials()
        youtube_service = self._build_youtube_service(credentials)
        sync_summary = youtube_service.sync_video_metadata(
            video_id=youtube_video_id,
            title=str(local_record.get("title") or ""),
            description=str(local_record.get("description") or ""),
            tags=list(json.loads(local_record.get("tags_json") or "[]")),
            privacy_status=self._desired_privacy_status(local_record),
            playlists=list(json.loads(local_record.get("playlists_json") or "[]")),
        )
        remote, comparisons = self._verify_synced_upload_with_retry(
            credentials=credentials,
            youtube_video_id=youtube_video_id,
            local_record=local_record,
        )
        if self._has_only_tag_mismatch(comparisons):
            accepted_tags = [f"#{tag}" for tag in (remote.get("tags") or [])]
            self.history_repo.update_remote_tags(youtube_video_id=youtube_video_id, tags=accepted_tags)
            self.management_repo.update_remote_tags(youtube_video_id=youtube_video_id, tags=accepted_tags)
            local_record = self.history_repo.get_history_record(youtube_video_id=youtube_video_id) or local_record
            comparisons = self._compare_local_and_remote(local_record, remote)
        return CommandResult(
            message="sync_upload_metadata",
            payload={
                "sync_summary": sync_summary,
                "remote": remote,
                "local_history": local_record,
                "comparisons": comparisons,
            },
        )

    def auth_login_with_expectation(
        self,
        *,
        expected_channel: str | None,
        expected_channel_id: str | None,
    ) -> CommandResult:
        self.initialize()
        self.auth_service.login()
        channel = self.get_authenticated_channel()
        try:
            self._validate_channel_expectation(channel, expected_channel, expected_channel_id)
        except ValidationError:
            self.auth_service.logout()
            raise
        return CommandResult(
            message="authenticated",
            payload={
                "token_file": str(self.paths.token_file),
                "channel_id": channel.channel_id,
                "channel_title": channel.title,
                "channel_handle": channel.handle,
            },
        )

    def _validate_channel_expectation(
        self,
        channel: ChannelInfo,
        expected_channel: str | None,
        expected_channel_id: str | None,
    ) -> None:
        expected_channel = (expected_channel or "").strip()
        expected_channel_id = (expected_channel_id or "").strip()
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

    def _compare_local_and_remote(
        self,
        local_record: dict[str, object] | None,
        remote: dict[str, object],
    ) -> list[dict[str, str]]:
        if not local_record:
            return []

        comparisons: list[dict[str, str]] = []
        comparisons.append(
            {
                "field": "title",
                "local": str(local_record.get("title") or ""),
                "remote": str(remote.get("title") or ""),
                "status": "match" if (local_record.get("title") or "") == (remote.get("title") or "") else "mismatch",
            }
        )
        comparisons.append(
            {
                "field": "description",
                "local": str(local_record.get("description") or ""),
                "remote": str(remote.get("description") or ""),
                "status": "match"
                if self._normalize_multiline_text(local_record.get("description"))
                == self._normalize_multiline_text(remote.get("description"))
                else "mismatch",
            }
        )
        local_tags = sorted(json.loads(local_record.get("tags_json") or "[]"))
        remote_tags = sorted([f"#{tag}" for tag in (remote.get("tags") or [])])
        comparisons.append(
            {
                "field": "tags",
                "local": ", ".join(local_tags),
                "remote": ", ".join(remote_tags),
                "status": "match" if local_tags == remote_tags else "mismatch",
            }
        )
        comparisons.append(
            {
                "field": "privacy_status",
                "local": "private" if local_record.get("upload_status") == "success" else str(local_record.get("upload_status") or ""),
                "remote": str(remote.get("privacy_status") or ""),
                "status": "match" if (remote.get("privacy_status") or "") == "private" else "mismatch",
            }
        )
        local_playlists = sorted(json.loads(local_record.get("playlists_json") or "[]"))
        remote_playlists = sorted([item.get("title", "") for item in (remote.get("playlists") or [])])
        comparisons.append(
            {
                "field": "playlists",
                "local": ", ".join(local_playlists),
                "remote": ", ".join(remote_playlists),
                "status": "match" if local_playlists == remote_playlists else "mismatch",
            }
        )
        return comparisons

    @staticmethod
    def _normalize_multiline_text(value: object) -> str:
        lines = str(value or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
        normalized = "\n".join(line.rstrip() for line in lines)
        return normalized.rstrip("\n")

    def _verify_synced_upload_with_retry(
        self,
        *,
        credentials,
        youtube_video_id: str,
        local_record: dict[str, object],
        attempts: int = 5,
        delay_seconds: float = 1.0,
    ) -> tuple[dict[str, object], list[dict[str, str]]]:
        remote: dict[str, object] = {}
        comparisons: list[dict[str, str]] = []
        synced_fields = {"title", "description", "tags", "privacy_status", "playlists"}

        for attempt in range(attempts):
            if attempt > 0:
                time.sleep(delay_seconds)
            remote = self._call_with_optional_quota_logger(
                fetch_video_verification,
                credentials,
                youtube_video_id,
            )
            comparisons = self._compare_local_and_remote(local_record, remote)
            mismatched_synced_fields = {
                item["field"] for item in comparisons if item.get("status") != "match"
            }.intersection(synced_fields)
            if not mismatched_synced_fields:
                break

        return remote, comparisons

    @staticmethod
    def _has_only_tag_mismatch(comparisons: list[dict[str, str]]) -> bool:
        mismatched_fields = [item.get("field", "") for item in comparisons if item.get("status") != "match"]
        return bool(mismatched_fields) and set(mismatched_fields) == {"tags"}

    def _summary_to_payload(self, summary: UploadSummary) -> dict[str, object]:
        return {
            "started_at": summary.started_at.isoformat(),
            "finished_at": summary.finished_at.isoformat(),
            "uploaded_count": summary.uploaded_count,
            "skipped_count": summary.skipped_count,
            "failed_count": summary.failed_count,
            "error_summary": summary.error_summary,
        }

    @staticmethod
    def _desired_privacy_status(local_record: dict[str, object]) -> str:
        upload_status = str(local_record.get("upload_status") or "")
        if upload_status == "success":
            return "private"
        return upload_status if upload_status in {"private", "unlisted", "public"} else "private"

    def _build_youtube_service(self, credentials):
        return self._call_with_optional_quota_logger(YouTubeUploadService, credentials)

    def _call_with_optional_quota_logger(self, func, *args):
        signature = inspect.signature(func)
        if "quota_logger" in signature.parameters:
            return func(*args, quota_logger=self.history_repo)
        return func(*args)

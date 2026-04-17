from __future__ import annotations

import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from iphoto2youtube_cli.app import Application
from iphoto2youtube_cli.config import AppPaths
from iphoto2youtube_cli.exceptions import ValidationError, YouTubeApiError
from iphoto2youtube_cli.metadata import YOUTUBE_DESCRIPTION_MAX_BYTES, YOUTUBE_TITLE_MAX_CHARS, compose_metadata
from iphoto2youtube_cli.models import UploadResult, VideoMetadataInput


class UploadFlowTest(unittest.TestCase):
    def test_compose_metadata_includes_event_name_in_title(self) -> None:
        metadata = VideoMetadataInput(
            video_path=Path("/tmp/sample.mov"),
            capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
            file_size_bytes=1,
            place="砧公園",
            content="花見",
            event_name="春の会",
        )

        composed = compose_metadata(metadata)

        self.assertEqual(composed.title, "2026-04-07-JST_砧公園_春の会_花見")

    def test_compose_metadata_omits_content_placeholder_from_title(self) -> None:
        metadata = VideoMetadataInput(
            video_path=Path("/tmp/sample.mov"),
            capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
            file_size_bytes=1,
            place="砧公園",
            event_name="春の会",
        )

        composed = compose_metadata(metadata)

        self.assertEqual(composed.title, "2026-04-07-JST_砧公園_春の会")

    def test_compose_metadata_deduplicates_event_name_and_content_in_title(self) -> None:
        metadata = VideoMetadataInput(
            video_path=Path("/tmp/sample.mov"),
            capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
            file_size_bytes=1,
            place="砧公園",
            content="花見",
            event_name="花見",
        )

        composed = compose_metadata(metadata)

        self.assertEqual(composed.title, "2026-04-07-JST_砧公園_花見")

    def test_compose_metadata_limits_title_and_tag_budget_for_youtube(self) -> None:
        metadata = VideoMetadataInput(
            video_path=Path("/tmp/sample.mov"),
            capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
            file_size_bytes=1,
            place="とても長い場所名" * 12,
            content="とても長い内容名" * 12,
            event_name="とても長いイベント名" * 12,
            participants=[f"参加者{i:02d}" * 4 for i in range(40)],
            camera_model="Insta360 X5",
        )

        composed = compose_metadata(metadata)

        self.assertLessEqual(len(composed.title), YOUTUBE_TITLE_MAX_CHARS)
        tag_budget = 0
        for index, tag in enumerate(composed.tags):
            if index > 0:
                tag_budget += 1
            tag_budget += len(tag.lstrip("#")) + (2 if " " in tag else 0)
        self.assertLessEqual(tag_budget, 500)
        self.assertNotIn("#参加者39参加者39参加者39参加者39", composed.tags)

    def test_compose_metadata_limits_description_bytes_and_sanitizes_angle_brackets(self) -> None:
        metadata = VideoMetadataInput(
            video_path=Path("/tmp/sample.mov"),
            capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
            file_size_bytes=1,
            place="砧公園",
            content="花見",
            participants=["<光弘>", "紀子"],
            note="メモ" * 4000 + "<script>",
        )

        composed = compose_metadata(metadata)

        self.assertLessEqual(len(composed.description.encode("utf-8")), YOUTUBE_DESCRIPTION_MAX_BYTES)
        self.assertNotIn("<", composed.description)
        self.assertNotIn(">", composed.description)

    def test_duplicate_upload_records_skipped_run_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            video_path = support_dir / "sample.mov"
            video_path.write_bytes(b"demo-video")
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            metadata = VideoMetadataInput(
                video_path=video_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=video_path.stat().st_size,
                duration_seconds=104.4,
                width=3840,
                height=2160,
                place="砧公園",
                content="花見",
                event_name="花見",
                participants=["Alice", "Bob"],
                camera_model="iPhone",
                playlists=["[散歩] 自宅_花見"],
            )
            composed = compose_metadata(metadata)
            uploaded_at = datetime(2026, 4, 8, 11, 12, 43)
            result = UploadResult(
                success=True,
                youtube_video_id="abc123",
                youtube_video_url="https://www.youtube.com/watch?v=abc123",
                uploaded_at=uploaded_at,
                privacy_status="private",
                upload_status="success",
            )
            app.history_repo.save_upload_result(metadata, composed, result)

            duplicate_result = app.upload(metadata)
            runs = app.runs_list(limit=5).payload["results"]

            self.assertEqual(duplicate_result.message, "skipped_duplicate")
            self.assertEqual(runs[0]["skipped_count"], 1)
            self.assertEqual(runs[0]["failed_count"], 0)

    def test_verify_upload_normalizes_description_line_endings_and_trailing_newlines(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)

            comparisons = app._compare_local_and_remote(
                {
                    "title": "2026-04-07-JST_砧公園_春の会_花見",
                    "description": "[検索用メタデータ]\n参加者: 光弘, 紀子\n[補足メモ]\n",
                    "tags_json": '["#花見"]',
                    "upload_status": "success",
                    "playlists_json": '["[散歩] 自宅_花見"]',
                },
                {
                    "title": "2026-04-07-JST_砧公園_春の会_花見",
                    "description": "[検索用メタデータ]\r\n参加者: 光弘, 紀子\r\n[補足メモ]",
                    "tags": ["花見"],
                    "privacy_status": "private",
                    "playlists": [{"title": "[散歩] 自宅_花見"}],
                },
            )

            description = next(item for item in comparisons if item["field"] == "description")
            self.assertEqual(description["status"], "match")

    def test_history_and_management_records_can_be_deleted_by_video_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            video_path = support_dir / "sample.mov"
            video_path.write_bytes(b"demo-video")
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            metadata = VideoMetadataInput(
                video_path=video_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=video_path.stat().st_size,
                place="砧公園",
                content="花見",
                event_name="春の会",
                participants=["光弘", "紀子"],
                playlists=["[散歩] 自宅_花見"],
            )
            composed = compose_metadata(metadata)
            result = UploadResult(
                success=True,
                youtube_video_id="abc123",
                youtube_video_url="https://www.youtube.com/watch?v=abc123",
                uploaded_at=datetime(2026, 4, 8, 11, 12, 43),
                privacy_status="private",
                upload_status="success",
            )
            app.history_repo.save_upload_result(metadata, composed, result)
            app.management_repo.upsert_video(metadata, composed, result)

            history_deleted = app.history_repo.delete_by_youtube_video_id("abc123")
            management_deleted = app.management_repo.delete_by_youtube_video_id("abc123")

            self.assertEqual(history_deleted, 1)
            self.assertEqual(management_deleted, 1)
            self.assertIsNone(app.history_repo.get_history_record(youtube_video_id="abc123"))

    def test_delete_uploaded_video_skips_remote_delete_for_dryrun(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            deleted = app.delete_uploaded_video(youtube_video_id="DRYRUN")

            self.assertEqual(deleted.message, "uploaded_video_deleted")
            self.assertTrue(deleted.payload["remote_skipped"])
            self.assertFalse(deleted.payload["remote_deleted"])

    def test_delete_uploaded_video_keeps_history_when_remote_video_not_found(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            video_path = support_dir / "sample.mov"
            video_path.write_bytes(b"demo-video")
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            metadata = VideoMetadataInput(
                video_path=video_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=video_path.stat().st_size,
                place="砧公園",
                content="花見",
                event_name="春の会",
                participants=["光弘", "紀子"],
                playlists=["[散歩] 自宅_花見"],
            )
            composed = compose_metadata(metadata)
            result = UploadResult(
                success=True,
                youtube_video_id="missing123",
                youtube_video_url="https://www.youtube.com/watch?v=missing123",
                uploaded_at=datetime(2026, 4, 8, 11, 12, 43),
                privacy_status="private",
                upload_status="success",
            )
            app.history_repo.save_upload_result(metadata, composed, result)
            app.management_repo.upsert_video(metadata, composed, result)

            class StubAuthService:
                def load_credentials(self):
                    return object()

            class StubYouTubeService:
                def __init__(self, credentials) -> None:
                    self.credentials = credentials

                def delete_video(self, video_id: str) -> None:
                    raise YouTubeApiError(
                        "not found",
                        operation="videos.delete",
                        category="not_found",
                        retryable=False,
                        status_code=404,
                        reason="videoNotFound",
                    )

            app.auth_service = StubAuthService()

            with patch("iphoto2youtube_cli.app.YouTubeUploadService", StubYouTubeService):
                with self.assertRaises(ValidationError):
                    app.delete_uploaded_video(youtube_video_id="missing123")

            self.assertIsNotNone(app.history_repo.get_history_record(youtube_video_id="missing123"))
            self.assertTrue(
                any(row["youtube_video_id"] == "missing123" for row in app.management_repo.fetch_all_for_ledger())
            )

    def test_sync_upload_metadata_retries_until_youtube_reflects_updated_tags(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            video_path = support_dir / "sample.mov"
            video_path.write_bytes(b"demo-video")
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            metadata = VideoMetadataInput(
                video_path=video_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=video_path.stat().st_size,
                place="砧公園",
                content="花見",
                event_name="花見",
                participants=["光弘", "紀子"],
                camera_model="HoverX1",
                playlists=["HoverX1"],
            )
            composed = compose_metadata(metadata)
            result = UploadResult(
                success=True,
                youtube_video_id="video123",
                youtube_video_url="https://www.youtube.com/watch?v=video123",
                uploaded_at=datetime(2026, 4, 8, 11, 12, 43),
                privacy_status="private",
                upload_status="success",
            )
            app.history_repo.save_upload_result(metadata, composed, result)

            class StubAuthService:
                def load_credentials(self):
                    return object()

            class StubYouTubeService:
                def __init__(self, credentials) -> None:
                    self.credentials = credentials

                def sync_video_metadata(self, **kwargs):
                    return {"updated_fields": ["tags"]}

            stale_remote = {
                "youtube_video_id": "video123",
                "title": composed.title,
                "description": composed.description,
                "tags": ["2026", "砧公園"],
                "privacy_status": "private",
                "playlists": [{"title": "HoverX1"}],
            }
            updated_remote = {
                "youtube_video_id": "video123",
                "title": composed.title,
                "description": composed.description,
                "tags": [tag.lstrip("#") for tag in composed.tags],
                "privacy_status": "private",
                "playlists": [{"title": "HoverX1"}],
            }

            app.auth_service = StubAuthService()

            with patch("iphoto2youtube_cli.app.YouTubeUploadService", StubYouTubeService), patch(
                "iphoto2youtube_cli.app.fetch_video_verification",
                side_effect=[stale_remote, updated_remote],
            ) as fetch_mock, patch("iphoto2youtube_cli.app.time.sleep") as sleep_mock:
                synced = app.sync_upload_metadata(youtube_video_id="video123")

            comparisons = synced.payload["comparisons"]
            tags = next(item for item in comparisons if item["field"] == "tags")
            self.assertEqual(tags["status"], "match")
            self.assertEqual(fetch_mock.call_count, 2)
            sleep_mock.assert_called_once_with(1.0)

    def test_sync_upload_metadata_accepts_youtube_sanitized_tags_into_local_history(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            video_path = support_dir / "sample.mov"
            video_path.write_bytes(b"demo-video")
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            metadata = VideoMetadataInput(
                video_path=video_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=video_path.stat().st_size,
                place="砧公園",
                content="花見",
                event_name="花見",
                participants=["光弘", "紀子"],
                camera_model="HoverX1",
                playlists=["HoverX1"],
                timezone="JST",
            )
            composed = compose_metadata(metadata)
            result = UploadResult(
                success=True,
                youtube_video_id="video456",
                youtube_video_url="https://www.youtube.com/watch?v=video456",
                uploaded_at=datetime(2026, 4, 8, 11, 12, 43),
                privacy_status="private",
                upload_status="success",
            )
            app.history_repo.save_upload_result(metadata, composed, result)
            app.management_repo.upsert_video(metadata, composed, result)

            class StubAuthService:
                def load_credentials(self):
                    return object()

            class StubYouTubeService:
                def __init__(self, credentials) -> None:
                    self.credentials = credentials

                def sync_video_metadata(self, **kwargs):
                    return {"updated_fields": ["tags"]}

            sanitized_remote = {
                "youtube_video_id": "video456",
                "title": composed.title,
                "description": composed.description,
                "tags": ["2026", "2026-04", "2026-04-07", "HoverX1", "砧公園", "花見"],
                "privacy_status": "private",
                "playlists": [{"title": "HoverX1"}],
            }

            app.auth_service = StubAuthService()

            with patch("iphoto2youtube_cli.app.YouTubeUploadService", StubYouTubeService), patch(
                "iphoto2youtube_cli.app.fetch_video_verification",
                side_effect=[sanitized_remote, sanitized_remote, sanitized_remote, sanitized_remote, sanitized_remote],
            ), patch("iphoto2youtube_cli.app.time.sleep"):
                synced = app.sync_upload_metadata(youtube_video_id="video456")

            comparisons = synced.payload["comparisons"]
            tags = next(item for item in comparisons if item["field"] == "tags")
            self.assertEqual(tags["status"], "match")
            stored = app.history_repo.get_history_record(youtube_video_id="video456")
            self.assertEqual(
                stored["tags_json"],
                '["#2026", "#2026-04", "#2026-04-07", "#HoverX1", "#砧公園", "#花見"]',
            )

    def test_history_list_supports_query_across_title_filename_and_playlist(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            first_path = support_dir / "hanami.mov"
            first_path.write_bytes(b"a")
            second_path = support_dir / "beach.mov"
            second_path.write_bytes(b"b")
            uploaded_at = datetime(2026, 4, 8, 11, 12, 43)

            first = VideoMetadataInput(
                video_path=first_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=first_path.stat().st_size,
                place="砧公園",
                content="花見",
                event_name="春の会",
                playlists=["[散歩] 自宅_花見"],
            )
            second = VideoMetadataInput(
                video_path=second_path,
                capture_datetime=datetime(2026, 4, 6, 10, 0, 0),
                file_size_bytes=second_path.stat().st_size,
                place="湘南",
                content="海",
                event_name="旅行",
                playlists=["[旅] 海"],
            )
            app.history_repo.save_upload_result(
                first,
                compose_metadata(first),
                UploadResult(True, "id1", "https://www.youtube.com/watch?v=id1", uploaded_at, "private"),
            )
            app.history_repo.save_upload_result(
                second,
                compose_metadata(second),
                UploadResult(True, "id2", "https://www.youtube.com/watch?v=id2", uploaded_at, "private"),
            )

            by_file = app.history_list(limit=10, query_text="hanami").payload["results"]
            by_title = app.history_list(limit=10, query_text="春の会").payload["results"]
            by_playlist = app.history_list(limit=10, query_text="[旅] 海").payload["results"]

            self.assertEqual(len(by_file), 1)
            self.assertEqual(by_file[0]["youtube_video_id"], "id1")
            self.assertEqual(len(by_title), 1)
            self.assertEqual(by_title[0]["youtube_video_id"], "id1")
            self.assertEqual(len(by_playlist), 1)
            self.assertEqual(by_playlist[0]["youtube_video_id"], "id2")

    def test_history_list_supports_capture_date_filter(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=support_dir / "config.json",
            )
            app = Application(paths)
            app.initialize()

            first_path = support_dir / "hanami.mov"
            first_path.write_bytes(b"a")
            second_path = support_dir / "beach.mov"
            second_path.write_bytes(b"b")
            uploaded_at = datetime(2026, 4, 8, 11, 12, 43)

            first = VideoMetadataInput(
                video_path=first_path,
                capture_datetime=datetime(2026, 4, 7, 14, 32, 10),
                file_size_bytes=first_path.stat().st_size,
                place="砧公園",
                content="花見",
                event_name="春の会",
                playlists=["[散歩] 自宅_花見"],
            )
            second = VideoMetadataInput(
                video_path=second_path,
                capture_datetime=datetime(2026, 4, 6, 10, 0, 0),
                file_size_bytes=second_path.stat().st_size,
                place="湘南",
                content="海",
                event_name="旅行",
                playlists=["[旅] 海"],
            )
            app.history_repo.save_upload_result(
                first,
                compose_metadata(first),
                UploadResult(True, "id1", "https://www.youtube.com/watch?v=id1", uploaded_at, "private"),
            )
            app.history_repo.save_upload_result(
                second,
                compose_metadata(second),
                UploadResult(True, "id2", "https://www.youtube.com/watch?v=id2", uploaded_at, "private"),
            )

            by_capture_date = app.history_list(limit=10, capture_date="2026-04-07").payload["results"]

            self.assertEqual(len(by_capture_date), 1)
            self.assertEqual(by_capture_date[0]["youtube_video_id"], "id1")

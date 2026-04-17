from __future__ import annotations

import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from iphoto2youtube_cli.app import Application
from iphoto2youtube_cli.config import AppPaths


class QuotaUsageTest(unittest.TestCase):
    def test_auth_status_includes_estimated_daily_quota_usage(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            paths = AppPaths(
                support_dir=root,
                credentials_file=root / "client_secret.json",
                token_file=root / "token.json",
                history_db=root / "upload_history.db",
                management_db=root / "management.db",
                ledger_csv=root / "ledger.csv",
                settings_file=root / "config.json",
            )
            app = Application(paths)
            app.initialize()
            app.history_repo.record_api_quota_usage(operation="videos.insert", quota_cost=1600)
            app.history_repo.record_api_quota_usage(operation="playlistItems.insert", quota_cost=50)

            result = app.auth_status()
            quota = result.payload["youtube_api_quota"]

            self.assertEqual(quota["used"], 150)
            self.assertEqual(quota["limit"], 10000)
            self.assertEqual(quota["remaining"], 9850)
            self.assertTrue(quota["is_estimated"])
            self.assertEqual(quota["breakdown"][0]["operation"], "videos.insert")
            self.assertEqual(quota["breakdown"][0]["used"], 100)
            self.assertEqual(quota["breakdown"][1]["operation"], "playlistItems.insert")

    def test_daily_quota_uses_pacific_reset_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            paths = AppPaths(
                support_dir=root,
                credentials_file=root / "client_secret.json",
                token_file=root / "token.json",
                history_db=root / "upload_history.db",
                management_db=root / "management.db",
                ledger_csv=root / "ledger.csv",
                settings_file=root / "config.json",
            )
            app = Application(paths)
            app.initialize()
            jst = ZoneInfo("Asia/Tokyo")
            app.history_repo._current_quota_window = lambda: {
                "start_utc": datetime(2026, 4, 15, 7, 0, tzinfo=timezone.utc),
                "end_utc": datetime(2026, 4, 16, 7, 0, tzinfo=timezone.utc),
                "start_jst": datetime(2026, 4, 15, 16, 0, tzinfo=jst),
                "end_jst": datetime(2026, 4, 16, 16, 0, tzinfo=jst),
            }
            app.history_repo.record_api_quota_usage(
                operation="videos.insert",
                quota_cost=1600,
                occurred_at=datetime(2026, 4, 15, 6, 59, tzinfo=timezone.utc),
            )
            app.history_repo.record_api_quota_usage(
                operation="videos.insert",
                quota_cost=1600,
                occurred_at=datetime(2026, 4, 15, 7, 1, tzinfo=timezone.utc),
            )

            quota = app.history_repo.get_daily_api_quota_usage()
            self.assertEqual(quota["used"], 100)

    def test_daily_quota_backfills_successful_uploads_when_log_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            paths = AppPaths(
                support_dir=root,
                credentials_file=root / "client_secret.json",
                token_file=root / "token.json",
                history_db=root / "upload_history.db",
                management_db=root / "management.db",
                ledger_csv=root / "ledger.csv",
                settings_file=root / "config.json",
            )
            app = Application(paths)
            app.initialize()
            conn = sqlite3.connect(paths.history_db)
            conn.execute(
                """
                INSERT INTO upload_history (
                  video_path, file_size_bytes, duration_seconds, width, height, capture_date, effective_capture_date,
                  effective_timezone, offset_time_original, capture_date_source, original_capture_date, metadata_rewritten_at,
                  youtube_video_id, youtube_video_url, title, description, tags_json, playlists_json, place, content,
                  event_name, participants_json, camera_model, original_filename, uploaded_at, upload_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "/tmp/test.mp4", 1, 1.0, 1, 1, "2026-04-15T00:00:00+09:00", "2026-04-15T00:00:00+09:00",
                    "JST", "+09:00", "manual_input", None, None, "abc123", "https://youtube.com/watch?v=abc123",
                    "title", "desc", "[]", "[]", "", "", "", "[]", "", "test.mp4",
                    "2026-04-15T08:10:00+00:00", "success",
                ),
            )
            conn.commit()
            conn.close()
            jst = ZoneInfo("Asia/Tokyo")
            app.history_repo._current_quota_window = lambda: {
                "start_utc": datetime(2026, 4, 15, 7, 0, tzinfo=timezone.utc),
                "end_utc": datetime(2026, 4, 16, 7, 0, tzinfo=timezone.utc),
                "start_jst": datetime(2026, 4, 15, 16, 0, tzinfo=jst),
                "end_jst": datetime(2026, 4, 16, 16, 0, tzinfo=jst),
            }

            quota = app.history_repo.get_daily_api_quota_usage()
            self.assertEqual(quota["used"], 100)

    def test_daily_quota_aggregates_playlist_related_operations_in_headline(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            paths = AppPaths(
                support_dir=root,
                credentials_file=root / "client_secret.json",
                token_file=root / "token.json",
                history_db=root / "upload_history.db",
                management_db=root / "management.db",
                ledger_csv=root / "ledger.csv",
                settings_file=root / "config.json",
            )
            app = Application(paths)
            app.initialize()
            app.history_repo.record_api_quota_usage(operation="videos.insert", quota_cost=1600)
            app.history_repo.record_api_quota_usage(operation="playlistItems.insert", quota_cost=50)
            app.history_repo.record_api_quota_usage(operation="playlists.list", quota_cost=1)
            app.history_repo.record_api_quota_usage(operation="channels.list", quota_cost=1)

            quota = app.history_repo.get_daily_api_quota_usage()

            self.assertEqual(quota["used"], 152)
            self.assertEqual(
                quota["breakdown"],
                [
                    {"operation": "videos.insert", "used": 100},
                    {"operation": "playlistItems.insert", "used": 50},
                    {"operation": "channels.list", "used": 1},
                    {"operation": "playlists.list", "used": 1},
                ],
            )
            self.assertEqual(sum(item["used"] for item in quota["breakdown"]), quota["used"])


if __name__ == "__main__":
    unittest.main()

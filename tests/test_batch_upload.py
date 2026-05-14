from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from iphoto2youtube_cli.app import Application
from iphoto2youtube_cli.cli import _load_batch_manifest
from iphoto2youtube_cli.config import AppPaths, AppSettings
from iphoto2youtube_cli.exceptions import YouTubeApiError
from iphoto2youtube_cli.models import UploadAttemptResult, UploadSummary


class BatchUploadTest(unittest.TestCase):
    def test_load_batch_manifest_merges_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            first = root / "a.mov"
            second = root / "b.mov"
            first.write_bytes(b"a")
            second.write_bytes(b"bb")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "defaults": {
                            "participants": ["Alice", "Bob"],
                            "playlists": ["[散歩] 自宅_花見"],
                            "playlist_privacy_status": "unlisted",
                        },
                        "videos": [
                            {
                                "video": str(first),
                                "capture_datetime": "2026-04-07 10:00:00",
                                "place": "砧公園",
                                "content": "花見",
                            },
                            {
                                "video": str(second),
                                "capture_datetime": "2026-04-07 11:00:00",
                                "place": "砧公園",
                                "content": "散歩",
                            },
                        ],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            items = _load_batch_manifest(manifest, AppSettings())

            self.assertEqual(len(items), 2)
            self.assertEqual(items[0].participants, ["Alice", "Bob"])
            self.assertEqual(items[1].playlist_privacy_status, "unlisted")

    def test_batch_upload_dry_run_returns_aggregate_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir) / "support"
            support_dir.mkdir(parents=True, exist_ok=True)
            first = Path(tmpdir) / "a.mov"
            second = Path(tmpdir) / "b.mov"
            first.write_bytes(b"a")
            second.write_bytes(b"bb")
            manifest = Path(tmpdir) / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "videos": [
                            {
                                "video": str(first),
                                "capture_datetime": "2026-04-07 10:00:00",
                                "place": "砧公園",
                                "content": "花見",
                            },
                            {
                                "video": str(second),
                                "capture_datetime": "2026-04-07 11:00:00",
                                "place": "砧公園",
                                "content": "散歩",
                            },
                        ]
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
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
            items = _load_batch_manifest(manifest, AppSettings())

            result = app.batch_upload(items, dry_run=True)

            summary = result.payload["summary"]
            self.assertEqual(result.message, "batch_completed")
            self.assertEqual(summary["total"], 2)
            self.assertEqual(summary["uploaded_count"], 2)
            self.assertEqual(summary["failed_count"], 0)

    def test_batch_upload_stops_after_upload_limit_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir) / "support"
            support_dir.mkdir(parents=True, exist_ok=True)
            first = Path(tmpdir) / "a.mov"
            second = Path(tmpdir) / "b.mov"
            third = Path(tmpdir) / "c.mov"
            first.write_bytes(b"a")
            second.write_bytes(b"bb")
            third.write_bytes(b"ccc")
            manifest = Path(tmpdir) / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "videos": [
                            {"video": str(first), "capture_datetime": "2026-04-07 10:00:00", "place": "砧公園", "content": "花見"},
                            {"video": str(second), "capture_datetime": "2026-04-07 11:00:00", "place": "砧公園", "content": "散歩"},
                            {"video": str(third), "capture_datetime": "2026-04-07 12:00:00", "place": "砧公園", "content": "休憩"},
                        ]
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
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
            items = _load_batch_manifest(manifest, AppSettings())

            uploaded = UploadAttemptResult(
                upload_result=None,
                summary=UploadSummary(
                    started_at=items[0].capture_datetime,
                    finished_at=items[0].capture_datetime,
                    uploaded_count=1,
                    skipped_count=0,
                    failed_count=0,
                ),
                status="uploaded",
                title="ok",
            )

            with patch.object(app, "perform_upload", side_effect=[
                uploaded,
                YouTubeApiError(
                    "YouTube チャンネルの日次アップロード本数制限に達しました: videos.insert.",
                    operation="videos.insert",
                    category="upload_limit",
                    retryable=False,
                    status_code=400,
                    reason="uploadLimitExceeded",
                ),
            ]) as perform_upload:
                result = app.batch_upload(items)

            summary = result.payload["summary"]
            self.assertEqual(summary["uploaded_count"], 1)
            self.assertEqual(summary["failed_count"], 2)
            self.assertEqual(len(result.payload["results"]), 3)
            self.assertEqual(perform_upload.call_count, 2)
            self.assertIn("未実行", result.payload["results"][2]["reason"])

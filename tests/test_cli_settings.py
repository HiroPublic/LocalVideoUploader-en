from __future__ import annotations

import argparse
import json
import tempfile
import unittest
from pathlib import Path

from iphoto2youtube_cli.cli import _apply_settings_defaults
from iphoto2youtube_cli.config import AppPaths, load_app_settings


class CliSettingsTest(unittest.TestCase):
    def test_apply_settings_defaults_uses_support_dir_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            settings_file = support_dir / "config.json"
            settings_file.write_text(
                json.dumps(
                    {
                        "expected_channel": "Sample Channel",
                        "default_playlist_privacy_status": "unlisted",
                        "default_library_name": "Archive",
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
                settings_file=settings_file,
            )
            settings = load_app_settings(paths)
            args = argparse.Namespace(
                expected_channel="",
                expected_channel_id="",
                privacy_status=None,
                playlist_privacy_status=None,
                timezone="JST",
                offset_time_original="+09:00",
                library_name="Local Files",
                capture_date_source="manual_input",
            )

            _apply_settings_defaults(args, settings)

            self.assertEqual(args.expected_channel, "Sample Channel")
            self.assertEqual(args.playlist_privacy_status, "unlisted")
            self.assertEqual(args.library_name, "Archive")

    def test_load_app_settings_uses_default_youtube_quota_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            settings_file = support_dir / "config.json"
            settings_file.write_text("{}", encoding="utf-8")
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=settings_file,
            )

            settings = load_app_settings(paths)

            self.assertEqual(settings.youtube_api_daily_quota_limit, 50_000)

    def test_load_app_settings_reads_youtube_quota_limit_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            support_dir = Path(tmpdir)
            settings_file = support_dir / "config.json"
            settings_file.write_text(
                json.dumps({"youtube_api_daily_quota_limit": 75000}),
                encoding="utf-8",
            )
            paths = AppPaths(
                support_dir=support_dir,
                credentials_file=support_dir / "client_secret.json",
                token_file=support_dir / "token.json",
                history_db=support_dir / "upload_history.db",
                management_db=support_dir / "management.db",
                ledger_csv=support_dir / "ledger.csv",
                settings_file=settings_file,
            )

            settings = load_app_settings(paths)

            self.assertEqual(settings.youtube_api_daily_quota_limit, 75_000)

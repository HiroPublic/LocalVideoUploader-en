from __future__ import annotations

import os
import json
from dataclasses import dataclass
from pathlib import Path

APP_NAME = "iPhoto2YouTube"
DEFAULT_TIMEZONE = "JST"
DEFAULT_OFFSET = "+09:00"
DEFAULT_PRIVACY_STATUS = "private"
DEFAULT_PLAYLIST_PRIVACY_STATUS = "private"
DEFAULT_YOUTUBE_API_DAILY_QUOTA_LIMIT = 50_000
YOUTUBE_SCOPES = [
    "https://www.googleapis.com/auth/youtube",
    "https://www.googleapis.com/auth/youtube.force-ssl",
    "https://www.googleapis.com/auth/youtube.upload",
]


def _default_support_dir() -> Path:
    custom_dir = os.environ.get("IPHOTO2YOUTUBE_HOME")
    if custom_dir:
        return Path(custom_dir).expanduser()
    return Path.cwd() / ".iphoto2youtube"


def load_dotenv(dotenv_path: Path | None = None) -> Path | None:
    path = dotenv_path or (Path.cwd() / ".env")
    if not path.exists() or not path.is_file():
        return None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        os.environ.setdefault(key, value)

    return path


@dataclass(frozen=True)
class AppPaths:
    support_dir: Path
    credentials_file: Path
    token_file: Path
    history_db: Path
    management_db: Path
    ledger_csv: Path
    settings_file: Path


@dataclass(frozen=True)
class AppSettings:
    expected_channel: str = ""
    expected_channel_id: str = ""
    default_privacy_status: str = DEFAULT_PRIVACY_STATUS
    default_playlist_privacy_status: str = DEFAULT_PLAYLIST_PRIVACY_STATUS
    default_library_name: str = "Local Files"
    default_timezone: str = DEFAULT_TIMEZONE
    default_offset_time_original: str = DEFAULT_OFFSET
    default_capture_date_source: str = "manual_input"
    youtube_api_daily_quota_limit: int = DEFAULT_YOUTUBE_API_DAILY_QUOTA_LIMIT


def _read_int_setting(raw: object, default: int) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def load_app_settings(paths: AppPaths) -> AppSettings:
    path = paths.settings_file
    if not path.exists() or not path.is_file():
        return AppSettings()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return AppSettings()
    if not isinstance(raw, dict):
        return AppSettings()
    return AppSettings(
        expected_channel=str(raw.get("expected_channel") or ""),
        expected_channel_id=str(raw.get("expected_channel_id") or ""),
        default_privacy_status=str(raw.get("default_privacy_status") or DEFAULT_PRIVACY_STATUS),
        default_playlist_privacy_status=str(
            raw.get("default_playlist_privacy_status") or DEFAULT_PLAYLIST_PRIVACY_STATUS
        ),
        default_library_name=str(raw.get("default_library_name") or "Local Files"),
        default_timezone=str(raw.get("default_timezone") or DEFAULT_TIMEZONE),
        default_offset_time_original=str(raw.get("default_offset_time_original") or DEFAULT_OFFSET),
        default_capture_date_source=str(raw.get("default_capture_date_source") or "manual_input"),
        youtube_api_daily_quota_limit=_read_int_setting(
            raw.get("youtube_api_daily_quota_limit"),
            DEFAULT_YOUTUBE_API_DAILY_QUOTA_LIMIT,
        ),
    )


def build_app_paths() -> AppPaths:
    support_dir = _default_support_dir()
    return AppPaths(
        support_dir=support_dir,
        credentials_file=support_dir / "client_secret.json",
        token_file=support_dir / "token.json",
        history_db=support_dir / "upload_history.db",
        management_db=support_dir / "management.db",
        ledger_csv=support_dir / "ledger.csv",
        settings_file=support_dir / "config.json",
    )

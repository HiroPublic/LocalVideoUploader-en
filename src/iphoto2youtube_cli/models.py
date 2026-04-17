from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .config import DEFAULT_OFFSET, DEFAULT_PRIVACY_STATUS, DEFAULT_TIMEZONE


@dataclass(slots=True)
class VideoMetadataInput:
    video_path: Path
    capture_datetime: datetime
    file_size_bytes: int
    duration_seconds: float | None = None
    width: int | None = None
    height: int | None = None
    timezone: str = DEFAULT_TIMEZONE
    offset_time_original: str = DEFAULT_OFFSET
    place: str = ""
    content: str = ""
    event_name: str = ""
    participants: list[str] = field(default_factory=list)
    camera_model: str = ""
    playlists: list[str] = field(default_factory=list)
    note: str = ""
    original_filename: str = ""
    library_name: str = "Local Files"
    capture_date_source: str = "manual_input"
    original_capture_datetime: datetime | None = None
    privacy_status: str = DEFAULT_PRIVACY_STATUS
    playlist_privacy_status: str = "private"


@dataclass(slots=True)
class ComposedMetadata:
    title: str
    description: str
    tags: list[str]
    playlists: list[str]
    title_base: str
    title_sequence: int


@dataclass(slots=True)
class UploadResult:
    success: bool
    youtube_video_id: str
    youtube_video_url: str
    uploaded_at: datetime
    privacy_status: str
    upload_status: str = "success"
    playlist_ids: dict[str, str] = field(default_factory=dict)


@dataclass(slots=True)
class UploadSummary:
    started_at: datetime
    finished_at: datetime
    uploaded_count: int
    skipped_count: int
    failed_count: int
    error_summary: str = ""


@dataclass(slots=True)
class UploadAttemptResult:
    upload_result: UploadResult | None
    summary: UploadSummary
    status: str
    reason: str = ""
    title: str = ""


@dataclass(slots=True)
class ChannelInfo:
    channel_id: str
    title: str
    handle: str = ""

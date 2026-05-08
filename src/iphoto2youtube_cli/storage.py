from __future__ import annotations

import csv
import json
import sqlite3
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from .exceptions import CsvExportError
from .media_info import probe_media_info
from .models import ComposedMetadata, UploadResult, UploadSummary, VideoMetadataInput

HISTORY_SCHEMA = """
CREATE TABLE IF NOT EXISTS upload_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  video_path TEXT NOT NULL,
  file_size_bytes INTEGER,
  duration_seconds REAL,
  width INTEGER,
  height INTEGER,
  capture_date TEXT,
  effective_capture_date TEXT,
  effective_timezone TEXT,
  offset_time_original TEXT,
  capture_date_source TEXT,
  original_capture_date TEXT,
  metadata_rewritten_at TEXT,
  youtube_video_id TEXT NOT NULL,
  youtube_video_url TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  tags_json TEXT NOT NULL,
  playlists_json TEXT NOT NULL,
  place TEXT,
  content TEXT,
  event_name TEXT,
  participants_json TEXT NOT NULL,
  camera_model TEXT,
  original_filename TEXT,
  uploaded_at TEXT NOT NULL,
  upload_status TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS execution_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  target_date TEXT NOT NULL,
  extracted_count INTEGER NOT NULL,
  uploaded_count INTEGER NOT NULL,
  skipped_count INTEGER NOT NULL,
  failed_count INTEGER NOT NULL,
  error_summary TEXT
);

CREATE TABLE IF NOT EXISTS api_quota_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  operation TEXT NOT NULL,
  quota_cost INTEGER NOT NULL,
  occurred_at TEXT NOT NULL
);
"""

MANAGEMENT_SCHEMA = """
CREATE TABLE IF NOT EXISTS video_management (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  youtube_video_id TEXT NOT NULL UNIQUE,
  youtube_video_url TEXT NOT NULL,
  title TEXT NOT NULL,
  effective_capture_date TEXT NOT NULL,
  effective_timezone TEXT NOT NULL,
  offset_time_original TEXT NOT NULL,
  file_size_bytes INTEGER,
  duration_seconds REAL,
  width INTEGER,
  height INTEGER,
  place TEXT,
  content TEXT,
  event_name TEXT,
  participants_json TEXT NOT NULL,
  camera_model TEXT,
  playlists_json TEXT NOT NULL,
  tags_json TEXT NOT NULL,
  original_filename TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata_dictionary (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  value TEXT NOT NULL,
  normalized_value TEXT NOT NULL,
  used_count INTEGER NOT NULL DEFAULT 0,
  last_used_at TEXT,
  UNIQUE(kind, normalized_value)
);
"""

LEDGER_COLUMNS = [
    "video_url",
    "youtube_video_id",
    "title",
    "effective_capture_date",
    "effective_timezone",
    "offset_time_original",
    "file_size_bytes",
    "duration_seconds",
    "width",
    "height",
    "place",
    "content",
    "event_name",
    "participants",
    "camera_model",
    "playlists",
    "original_filename",
]

PACIFIC_TZ = ZoneInfo("America/Los_Angeles")
JST_TZ = ZoneInfo("Asia/Tokyo")
CURRENT_QUOTA_COST_BY_OPERATION = {
    "channels.list": 1,
    "videos.list": 1,
    "playlists.list": 1,
    "playlistItems.list": 1,
    "videos.insert": 100,
    "playlists.insert": 50,
    "playlistItems.insert": 50,
    "videos.update": 50,
    "playlistItems.delete": 50,
    "videos.delete": 50,
}
API_DATA_RETENTION_DAYS = 30


class UploadHistoryRepository:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path

    def initialize(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path) as conn:
            conn.executescript(HISTORY_SCHEMA)
            self._ensure_column(conn, "upload_history", "file_size_bytes", "INTEGER")
            self._ensure_column(conn, "upload_history", "duration_seconds", "REAL")
            self._ensure_column(conn, "upload_history", "width", "INTEGER")
            self._ensure_column(conn, "upload_history", "height", "INTEGER")

    def purge_expired_api_data(self, *, now: datetime | None = None) -> dict[str, int]:
        cutoff = (now or datetime.now()) - timedelta(days=API_DATA_RETENTION_DAYS)
        cutoff_text = cutoff.isoformat()
        with sqlite3.connect(self.db_path) as conn:
            history_cursor = conn.execute(
                """
                DELETE FROM upload_history
                WHERE uploaded_at < ?
                """,
                (cutoff_text,),
            )
            quota_cursor = conn.execute(
                """
                DELETE FROM api_quota_log
                WHERE occurred_at < ?
                """,
                (cutoff_text,),
            )
            conn.commit()
        return {
            "history_deleted": int(history_cursor.rowcount or 0),
            "quota_deleted": int(quota_cursor.rowcount or 0),
        }

    def _ensure_column(
        self,
        conn: sqlite3.Connection,
        table_name: str,
        column_name: str,
        column_definition: str,
    ) -> None:
        rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
        existing_columns = {row[1] for row in rows}
        if column_name not in existing_columns:
            conn.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {column_definition}")
            conn.commit()

    def find_duplicate(self, metadata: VideoMetadataInput) -> dict[str, str] | None:
        resolved_path = str(metadata.video_path.resolve())
        original_path = str(metadata.video_path)
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                """
                SELECT youtube_video_id, youtube_video_url, title, uploaded_at
                FROM upload_history
                WHERE video_path IN (?, ?)
                  AND capture_date = ?
                  AND (file_size_bytes = ? OR file_size_bytes IS NULL)
                  AND upload_status = 'success'
                  AND youtube_video_id != 'DRYRUN'
                ORDER BY uploaded_at DESC
                LIMIT 1
                """,
                (
                    resolved_path,
                    original_path,
                    metadata.capture_datetime.isoformat(),
                    metadata.file_size_bytes,
                ),
            ).fetchone()
        if not row:
            return None
        return {
            "youtube_video_id": row["youtube_video_id"],
            "youtube_video_url": row["youtube_video_url"],
            "title": row["title"],
            "uploaded_at": row["uploaded_at"],
        }

    def next_collision_index(self, title_base: str) -> int:
        with sqlite3.connect(self.db_path) as conn:
            row = conn.execute(
                """
                SELECT COUNT(*)
                FROM upload_history
                WHERE title = ? OR title LIKE ?
                """,
                (title_base, f"{title_base}_%"),
            ).fetchone()
        return int(row[0]) if row else 0

    def save_upload_result(
        self,
        metadata: VideoMetadataInput,
        composed: ComposedMetadata,
        result: UploadResult,
    ) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                INSERT INTO upload_history (
                  video_path, file_size_bytes, duration_seconds, width, height, capture_date, effective_capture_date, effective_timezone,
                  offset_time_original, capture_date_source, original_capture_date,
                  metadata_rewritten_at, youtube_video_id, youtube_video_url, title,
                  description, tags_json, playlists_json, place, content, event_name,
                  participants_json, camera_model, original_filename, uploaded_at, upload_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    str(metadata.video_path.resolve()),
                    metadata.file_size_bytes,
                    metadata.duration_seconds,
                    metadata.width,
                    metadata.height,
                    metadata.capture_datetime.isoformat(),
                    metadata.capture_datetime.isoformat(),
                    metadata.timezone,
                    metadata.offset_time_original,
                    metadata.capture_date_source,
                    metadata.original_capture_datetime.isoformat()
                    if metadata.original_capture_datetime
                    else None,
                    None,
                    result.youtube_video_id,
                    result.youtube_video_url,
                    composed.title,
                    composed.description,
                    json.dumps(composed.tags, ensure_ascii=False),
                    json.dumps(composed.playlists, ensure_ascii=False),
                    metadata.place,
                    metadata.content,
                    metadata.event_name,
                    json.dumps(metadata.participants, ensure_ascii=False),
                    metadata.camera_model,
                    metadata.original_filename,
                    result.uploaded_at.isoformat(),
                    result.upload_status,
                ),
            )
            conn.commit()

    def save_execution_log(self, summary: UploadSummary, target_date: str) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                INSERT INTO execution_log (
                  started_at, finished_at, target_date, extracted_count, uploaded_count,
                  skipped_count, failed_count, error_summary
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    summary.started_at.isoformat(),
                    summary.finished_at.isoformat(),
                    target_date,
                    summary.uploaded_count + summary.skipped_count + summary.failed_count,
                    summary.uploaded_count,
                    summary.skipped_count,
                    summary.failed_count,
                    summary.error_summary,
                ),
            )
            conn.commit()

    def list_execution_logs(self, *, limit: int = 20) -> list[dict[str, object]]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT *
                FROM execution_log
                ORDER BY id DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def get_execution_log(self, *, execution_id: int) -> dict[str, object] | None:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                """
                SELECT *
                FROM execution_log
                WHERE id = ?
                LIMIT 1
                """,
                (execution_id,),
            ).fetchone()
        return dict(row) if row else None

    def record_api_quota_usage(
        self,
        *,
        operation: str,
        quota_cost: int,
        occurred_at: datetime | None = None,
    ) -> None:
        timestamp = self._normalize_timestamp(occurred_at).isoformat()
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                INSERT INTO api_quota_log (operation, quota_cost, occurred_at)
                VALUES (?, ?, ?)
                """,
                (operation, quota_cost, timestamp),
            )
            conn.commit()

    def get_daily_api_quota_usage(
        self,
        *,
        target_date: str | None = None,
        daily_limit: int = 10_000,
    ) -> dict[str, object]:
        quota_window = self._current_quota_window()
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT operation, quota_cost, occurred_at
                FROM api_quota_log
                """
            ).fetchall()

        operation_totals: dict[str, int] = {}
        operation_counts: dict[str, int] = {}
        for row in rows:
            occurred_at = self._parse_timestamp(str(row["occurred_at"] or ""))
            if occurred_at is None:
                continue
            if not (quota_window["start_utc"] <= occurred_at < quota_window["end_utc"]):
                continue
            operation = str(row["operation"] or "")
            operation_counts[operation] = operation_counts.get(operation, 0) + 1
            normalized_cost = CURRENT_QUOTA_COST_BY_OPERATION.get(operation, int(row["quota_cost"] or 0))
            operation_totals[operation] = operation_totals.get(operation, 0) + normalized_cost

        successful_uploads, uploads_with_playlists = self._count_successful_uploads_in_window(
            start_utc=quota_window["start_utc"],
            end_utc=quota_window["end_utc"],
        )
        logged_video_inserts = operation_counts.get("videos.insert", 0)
        authoritative_video_inserts = max(successful_uploads, logged_video_inserts)
        operation_totals["videos.insert"] = authoritative_video_inserts * CURRENT_QUOTA_COST_BY_OPERATION["videos.insert"]
        logged_playlist_item_inserts = operation_counts.get("playlistItems.insert", 0)
        authoritative_playlist_item_inserts = max(uploads_with_playlists, logged_playlist_item_inserts)
        operation_totals["playlistItems.insert"] = (
            authoritative_playlist_item_inserts * CURRENT_QUOTA_COST_BY_OPERATION["playlistItems.insert"]
        )
        logged_playlists_list = operation_counts.get("playlists.list", 0)
        authoritative_playlists_list = max(uploads_with_playlists, logged_playlists_list)
        operation_totals["playlists.list"] = authoritative_playlists_list * CURRENT_QUOTA_COST_BY_OPERATION["playlists.list"]

        breakdown = [
            {"operation": operation, "used": used}
            for operation, used in sorted(operation_totals.items(), key=lambda item: (-item[1], item[0]))
            if used > 0
        ]
        used = sum(item["used"] for item in breakdown)
        remaining = max(daily_limit - used, 0)
        return {
            "date": quota_window["start_jst"].strftime("%Y-%m-%d"),
            "used": used,
            "limit": daily_limit,
            "remaining": remaining,
            "usage_ratio": (used / daily_limit) if daily_limit > 0 else 0.0,
            "is_estimated": True,
            "window_start_text": quota_window["start_jst"].strftime("%Y-%m-%d %H:%M JST"),
            "window_end_text": (quota_window["end_jst"] - timedelta(minutes=1)).strftime("%Y-%m-%d %H:%M JST"),
            "window_label": (
                f"{quota_window['start_jst'].strftime('%Y-%m-%d %H:%M JST')} - "
                f"{(quota_window['end_jst'] - timedelta(minutes=1)).strftime('%Y-%m-%d %H:%M JST')}"
            ),
            "breakdown": breakdown,
        }

    def _current_quota_window(self) -> dict[str, datetime]:
        now_utc = datetime.now(timezone.utc)
        now_pt = now_utc.astimezone(PACIFIC_TZ)
        start_pt = datetime.combine(now_pt.date(), time.min, tzinfo=PACIFIC_TZ)
        end_pt = start_pt + timedelta(days=1)
        return {
            "start_utc": start_pt.astimezone(timezone.utc),
            "end_utc": end_pt.astimezone(timezone.utc),
            "start_jst": start_pt.astimezone(JST_TZ),
            "end_jst": end_pt.astimezone(JST_TZ),
        }

    def _count_successful_uploads_in_window(self, *, start_utc: datetime, end_utc: datetime) -> tuple[int, int]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT uploaded_at, playlists_json
                FROM upload_history
                WHERE upload_status = 'success'
                  AND youtube_video_id != 'DRYRUN'
                """
            ).fetchall()

        count = 0
        count_with_playlists = 0
        for row in rows:
            uploaded_at = self._parse_timestamp(str(row["uploaded_at"] or ""))
            if uploaded_at is None:
                continue
            if start_utc <= uploaded_at < end_utc:
                count += 1
                playlists_json = str(row["playlists_json"] or "[]")
                try:
                    playlists = json.loads(playlists_json)
                except json.JSONDecodeError:
                    playlists = []
                if playlists:
                    count_with_playlists += 1
        return count, count_with_playlists

    @staticmethod
    def _normalize_timestamp(value: datetime | None) -> datetime:
        if value is None:
            return datetime.now(timezone.utc)
        if value.tzinfo is None:
            local_tz = datetime.now().astimezone().tzinfo or timezone.utc
            return value.replace(tzinfo=local_tz).astimezone(timezone.utc)
        return value.astimezone(timezone.utc)

    @staticmethod
    def _parse_timestamp(value: str) -> datetime | None:
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            local_tz = datetime.now().astimezone().tzinfo or timezone.utc
            parsed = parsed.replace(tzinfo=local_tz)
        return parsed.astimezone(timezone.utc)

    def list_history(
        self,
        *,
        limit: int = 20,
        upload_status: str | None = None,
        query_text: str | None = None,
        capture_date: str | None = None,
    ) -> list[dict[str, object]]:
        clauses: list[str] = []
        params: list[object] = []
        if upload_status:
            clauses.append("upload_status = ?")
            params.append(upload_status)
        if capture_date:
            normalized_capture_date = capture_date.strip()
            if normalized_capture_date:
                clauses.append("capture_date LIKE ?")
                params.append(f"{normalized_capture_date}%")
        if query_text:
            like = f"%{query_text}%"
            clauses.append(
                "("
                "title LIKE ? OR "
                "video_path LIKE ? OR "
                "place LIKE ? OR "
                "content LIKE ? OR "
                "event_name LIKE ? OR "
                "participants_json LIKE ? OR "
                "camera_model LIKE ? OR "
                "playlists_json LIKE ?"
                ")"
            )
            params.extend([like, like, like, like, like, like, like, like])
        where_sql = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        query = f"""
            SELECT
              id,
              youtube_video_id,
              youtube_video_url,
              title,
              video_path,
              file_size_bytes,
              duration_seconds,
              width,
              height,
              capture_date,
              effective_timezone,
              place,
              content,
              event_name,
              participants_json,
              camera_model,
              playlists_json,
              uploaded_at,
              upload_status
            FROM upload_history
            {where_sql}
            ORDER BY id DESC
            LIMIT ?
        """
        params.append(limit)
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(query, params).fetchall()
        results: list[dict[str, object]] = []
        for row in rows:
            item = dict(row)
            item["participants"] = ", ".join(json.loads(item.get("participants_json") or "[]"))
            item["playlists"] = ", ".join(json.loads(item.get("playlists_json") or "[]"))
            results.append(item)
        return results

    def get_history_record(
        self,
        *,
        history_id: int | None = None,
        youtube_video_id: str | None = None,
    ) -> dict[str, object] | None:
        if history_id is None and not youtube_video_id:
            return None
        clauses: list[str] = []
        params: list[object] = []
        if history_id is not None:
            clauses.append("id = ?")
            params.append(history_id)
        if youtube_video_id:
            clauses.append("youtube_video_id = ?")
            params.append(youtube_video_id)
        where_sql = " AND ".join(clauses)
        query = f"""
            SELECT *
            FROM upload_history
            WHERE {where_sql}
            ORDER BY id DESC
            LIMIT 1
        """
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(query, params).fetchone()
        return dict(row) if row else None

    def backfill_media_info(self) -> dict[str, int]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT id, video_path, file_size_bytes, duration_seconds, width, height
                FROM upload_history
                WHERE youtube_video_id != 'DRYRUN'
                  AND (
                    file_size_bytes IS NULL OR
                    duration_seconds IS NULL OR
                    width IS NULL OR
                    height IS NULL
                  )
                ORDER BY id ASC
                """
            ).fetchall()

            scanned = 0
            updated = 0
            missing_files = 0
            for row in rows:
                scanned += 1
                video_path = Path(row["video_path"]).expanduser()
                if not video_path.exists():
                    missing_files += 1
                    continue
                info = probe_media_info(video_path)
                conn.execute(
                    """
                    UPDATE upload_history
                    SET file_size_bytes = COALESCE(file_size_bytes, ?),
                        duration_seconds = COALESCE(duration_seconds, ?),
                        width = COALESCE(width, ?),
                        height = COALESCE(height, ?)
                    WHERE id = ?
                    """,
                    (
                        info.file_size_bytes,
                        info.duration_seconds,
                        info.width,
                        info.height,
                        row["id"],
                    ),
                )
                updated += 1
            conn.commit()
        return {"scanned": scanned, "updated": updated, "missing_files": missing_files}

    def delete_by_youtube_video_id(self, youtube_video_id: str) -> int:
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(
                """
                DELETE FROM upload_history
                WHERE youtube_video_id = ?
                """,
                (youtube_video_id,),
            )
            conn.commit()
        return int(cursor.rowcount or 0)

    def update_remote_tags(self, *, youtube_video_id: str, tags: list[str]) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                UPDATE upload_history
                SET tags_json = ?
                WHERE youtube_video_id = ?
                """,
                (json.dumps(tags, ensure_ascii=False), youtube_video_id),
            )
            conn.commit()

    def latest_successful_records(self) -> list[dict[str, object]]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT h.*
                FROM upload_history h
                INNER JOIN (
                  SELECT youtube_video_id, MAX(id) AS max_id
                  FROM upload_history
                  WHERE upload_status = 'success'
                    AND youtube_video_id != 'DRYRUN'
                  GROUP BY youtube_video_id
                ) latest
                  ON h.youtube_video_id = latest.youtube_video_id
                 AND h.id = latest.max_id
                ORDER BY h.id ASC
                """
            ).fetchall()
        return [dict(row) for row in rows]


class VideoManagementRepository:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path

    def initialize(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path) as conn:
            conn.executescript(MANAGEMENT_SCHEMA)
            self._ensure_column(conn, "video_management", "title", "TEXT")
            self._ensure_column(conn, "video_management", "file_size_bytes", "INTEGER")
            self._ensure_column(conn, "video_management", "duration_seconds", "REAL")
            self._ensure_column(conn, "video_management", "width", "INTEGER")
            self._ensure_column(conn, "video_management", "height", "INTEGER")

    def purge_expired_api_data(self, *, now: datetime | None = None) -> int:
        cutoff = (now or datetime.now()) - timedelta(days=API_DATA_RETENTION_DAYS)
        cutoff_text = cutoff.isoformat()
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(
                """
                DELETE FROM video_management
                WHERE COALESCE(updated_at, created_at) < ?
                """,
                (cutoff_text,),
            )
            conn.commit()
        return int(cursor.rowcount or 0)

    def _ensure_column(
        self,
        conn: sqlite3.Connection,
        table_name: str,
        column_name: str,
        column_definition: str,
    ) -> None:
        rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
        existing_columns = {row[1] for row in rows}
        if column_name not in existing_columns:
            conn.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {column_definition}")
            conn.commit()

    def upsert_video(self, metadata: VideoMetadataInput, composed: ComposedMetadata, result: UploadResult) -> None:
        now = datetime.now().isoformat()
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                INSERT INTO video_management (
                  youtube_video_id, youtube_video_url, title, effective_capture_date, effective_timezone,
                  offset_time_original, file_size_bytes, duration_seconds, width, height,
                  place, content, event_name, participants_json,
                  camera_model, playlists_json, tags_json, original_filename, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(youtube_video_id) DO UPDATE SET
                  youtube_video_url = excluded.youtube_video_url,
                  title = excluded.title,
                  effective_capture_date = excluded.effective_capture_date,
                  effective_timezone = excluded.effective_timezone,
                  offset_time_original = excluded.offset_time_original,
                  file_size_bytes = excluded.file_size_bytes,
                  duration_seconds = excluded.duration_seconds,
                  width = excluded.width,
                  height = excluded.height,
                  place = excluded.place,
                  content = excluded.content,
                  event_name = excluded.event_name,
                  participants_json = excluded.participants_json,
                  camera_model = excluded.camera_model,
                  playlists_json = excluded.playlists_json,
                  tags_json = excluded.tags_json,
                  original_filename = excluded.original_filename,
                  updated_at = excluded.updated_at
                """,
                (
                    result.youtube_video_id,
                    result.youtube_video_url,
                    composed.title,
                    metadata.capture_datetime.isoformat(),
                    metadata.timezone,
                    metadata.offset_time_original,
                    metadata.file_size_bytes,
                    metadata.duration_seconds,
                    metadata.width,
                    metadata.height,
                    metadata.place,
                    metadata.content,
                    metadata.event_name,
                    json.dumps(metadata.participants, ensure_ascii=False),
                    metadata.camera_model,
                    json.dumps(composed.playlists, ensure_ascii=False),
                    json.dumps(composed.tags, ensure_ascii=False),
                    metadata.original_filename,
                    now,
                    now,
                ),
            )
            self._update_metadata_dictionary(conn, metadata, composed.tags, now)
            conn.commit()

    def update_remote_tags(self, *, youtube_video_id: str, tags: list[str]) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                UPDATE video_management
                SET tags_json = ?, updated_at = ?
                WHERE youtube_video_id = ?
                """,
                (json.dumps(tags, ensure_ascii=False), datetime.now().isoformat(), youtube_video_id),
            )
            conn.commit()

    def _update_metadata_dictionary(
        self,
        conn: sqlite3.Connection,
        metadata: VideoMetadataInput,
        tags: list[str],
        now: str,
    ) -> None:
        candidates: list[tuple[str, str]] = []
        if metadata.place:
            candidates.append(("place", metadata.place))
        if metadata.event_name:
            candidates.append(("event_name", metadata.event_name))
        for participant in metadata.participants:
            candidates.append(("participant", participant))
        if metadata.camera_model:
            candidates.append(("camera_model", metadata.camera_model))
        for tag in tags:
            candidates.append(("tag", tag))
        for kind, value in candidates:
            normalized_value = value.casefold().strip()
            conn.execute(
                """
                INSERT INTO metadata_dictionary (kind, value, normalized_value, used_count, last_used_at)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(kind, normalized_value) DO UPDATE SET
                  used_count = used_count + 1,
                  last_used_at = excluded.last_used_at
                """,
                (kind, value, normalized_value, now),
            )

    def fetch_all_for_ledger(self) -> list[dict[str, str]]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT
                  youtube_video_url AS video_url,
                  youtube_video_id,
                  title,
                  effective_capture_date,
                  effective_timezone,
                  offset_time_original,
                  file_size_bytes,
                  duration_seconds,
                  width,
                  height,
                  place,
                  content,
                  event_name,
                  participants_json,
                  camera_model,
                  playlists_json,
                  original_filename
                FROM video_management
                ORDER BY effective_capture_date ASC, youtube_video_id ASC
                """
            ).fetchall()
        records: list[dict[str, str]] = []
        for row in rows:
            records.append(
                {
                    "video_url": row["video_url"],
                    "youtube_video_id": row["youtube_video_id"],
                    "title": row["title"] or "",
                    "effective_capture_date": row["effective_capture_date"],
                    "effective_timezone": row["effective_timezone"],
                    "offset_time_original": row["offset_time_original"],
                    "file_size_bytes": row["file_size_bytes"] or "",
                    "duration_seconds": row["duration_seconds"] or "",
                    "width": row["width"] or "",
                    "height": row["height"] or "",
                    "place": row["place"] or "",
                    "content": row["content"] or "",
                    "event_name": row["event_name"] or "",
                    "participants": ", ".join(json.loads(row["participants_json"])),
                    "camera_model": row["camera_model"] or "",
                    "playlists": ", ".join(json.loads(row["playlists_json"])),
                    "original_filename": row["original_filename"] or "",
                }
            )
        return records

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
    ) -> list[dict[str, str | int | float]]:
        clauses: list[str] = []
        params: list[object] = []
        if title_contains:
            clauses.append("title LIKE ?")
            params.append(f"%{title_contains}%")
        if place:
            clauses.append("place LIKE ?")
            params.append(f"%{place}%")
        if event_name:
            clauses.append("event_name LIKE ?")
            params.append(f"%{event_name}%")
        if camera_model:
            clauses.append("camera_model LIKE ?")
            params.append(f"%{camera_model}%")
        if participant:
            clauses.append("participants_json LIKE ?")
            params.append(f"%{participant}%")
        if playlist:
            clauses.append("playlists_json LIKE ?")
            params.append(f"%{playlist}%")
        if min_duration is not None:
            clauses.append("duration_seconds >= ?")
            params.append(min_duration)
        if max_duration is not None:
            clauses.append("duration_seconds <= ?")
            params.append(max_duration)
        if min_width is not None:
            clauses.append("width >= ?")
            params.append(min_width)
        if min_height is not None:
            clauses.append("height >= ?")
            params.append(min_height)
        if min_file_size is not None:
            clauses.append("file_size_bytes >= ?")
            params.append(min_file_size)

        where_sql = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        query = f"""
            SELECT
              youtube_video_id,
              youtube_video_url,
              title,
              effective_capture_date,
              effective_timezone,
              offset_time_original,
              file_size_bytes,
              duration_seconds,
              width,
              height,
              place,
              content,
              event_name,
              camera_model,
              original_filename
            FROM video_management
            {where_sql}
            ORDER BY effective_capture_date DESC, updated_at DESC
            LIMIT ?
        """
        params.append(limit)
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(query, params).fetchall()
        return [dict(row) for row in rows]

    def backfill_from_history(self, history_records: list[dict[str, object]]) -> int:
        updated = 0
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            for history in history_records:
                row = conn.execute(
                    """
                    SELECT id, title, file_size_bytes, duration_seconds, width, height, original_filename
                    FROM video_management
                    WHERE youtube_video_id = ?
                    """,
                    (history["youtube_video_id"],),
                ).fetchone()
                if not row:
                    continue
                if (
                    row["title"]
                    and row["file_size_bytes"] is not None
                    and row["duration_seconds"] is not None
                    and row["width"] is not None
                    and row["height"] is not None
                    and row["original_filename"]
                ):
                    continue

                conn.execute(
                    """
                    UPDATE video_management
                    SET title = COALESCE(NULLIF(title, ''), ?),
                        file_size_bytes = COALESCE(file_size_bytes, ?),
                        duration_seconds = COALESCE(duration_seconds, ?),
                        width = COALESCE(width, ?),
                        height = COALESCE(height, ?),
                        original_filename = COALESCE(NULLIF(original_filename, ''), ?),
                        updated_at = ?
                    WHERE id = ?
                    """,
                    (
                        history.get("title"),
                        history.get("file_size_bytes"),
                        history.get("duration_seconds"),
                        history.get("width"),
                        history.get("height"),
                        history.get("original_filename"),
                        datetime.now().isoformat(),
                        row["id"],
                    ),
                )
                updated += 1
            conn.commit()
        return updated

    def delete_by_youtube_video_id(self, youtube_video_id: str) -> int:
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(
                """
                DELETE FROM video_management
                WHERE youtube_video_id = ?
                """,
                (youtube_video_id,),
            )
            conn.commit()
        return int(cursor.rowcount or 0)


class LedgerExportService:
    def export_csv(self, records: list[dict[str, str]], output_path: Path) -> None:
        try:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with output_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=LEDGER_COLUMNS)
                writer.writeheader()
                writer.writerows(records)
        except OSError as exc:
            raise CsvExportError(f"CSV 出力に失敗しました: {output_path}: {exc}") from exc

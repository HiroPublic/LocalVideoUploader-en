# Local Video Uploader

Local Video Uploader is a personal-use macOS app that uploads local video files and videos selected from the macOS Photo Library to the signed-in user's YouTube channel. It combines a SwiftUI desktop UI with a Python CLI for YouTube Data API operations and local records.

Every upload, metadata sync, and deletion begins with an explicit user action. The app has no server component, scheduled jobs, or unattended uploader.

## Features

- Google OAuth 2.0 sign-in, destination-channel display, and estimated daily API quota tracking.
- Multiple `.mov` / `.mp4` uploads with dry run, confirmation, progress reporting, and duplicate detection.
- Shared and per-video metadata for titles, descriptions, tags, playlists, and privacy settings.
- Missing-playlist creation, playlist rollover handling, remote metadata verification, and mismatch repair.
- Photo Library import by capture date, local cache management, controlled source deletion, and filename-based Vlog / Insta360 / HoverX1 presets.
- Upload history, deletion history, history calendar, CSV ledger, and reusable metadata history.

## Requirements

- macOS 14 or later
- Xcode command-line tools
- Python 3.11 or later
- A Google Cloud OAuth desktop-client JSON file with YouTube Data API enabled
- A Google account that can upload to the intended channel

## Setup

Install the Python CLI from the repository root:

```bash
python3 -m venv .venv
.venv/bin/pip install -e .
```

Set up local application data and OAuth:

```bash
mkdir -p .iphoto2youtube
cp /path/to/client_secret.json .iphoto2youtube/client_secret.json
cp config.example.json .iphoto2youtube/config.json
```

Edit `.iphoto2youtube/config.json` to set a channel guard, metadata defaults, or the local daily API quota limit. Do not commit this directory: it can contain OAuth credentials, tokens, and local history.

Build, stage, and open the native app:

```bash
./script/build_and_run.sh
```

The staged app is `dist/Local Video Uploader.app`; use `--build-only` or `--verify` to skip opening it.

## Workflow

1. Sign in and confirm the displayed channel.
2. Add local videos or load one date of Photo Library videos, then review metadata.
3. Use **Dry Run** to validate metadata and local record creation without calling YouTube.
4. Select **Upload**, review the confirmation dialog, and approve it.
5. Review the verification report and Recent History. **Resolve Mismatch** writes the local recorded metadata back to the YouTube video.

On the Photos screen, numeric `.mp4` files are Vlog candidates, `VID_` files are Insta360 candidates, and `HOVER_` files are HoverX1 candidates. **Photo Workflow** is started and confirmed by the user, processes applicable groups in that order, and stops at the first error. It deletes Insta360 and HoverX1 source assets only after their upload succeeds.

## Local data

The default support directory is `./.iphoto2youtube/`. The CLI also accepts `IPHOTO2YOUTUBE_HOME` or `--support-dir`; the desktop app explicitly passes its support directory to the CLI.

| File | Purpose |
| --- | --- |
| `client_secret.json` / `token.json` | OAuth configuration and local OAuth token |
| `config.json` | Channel guard, defaults, and quota limit |
| `upload_history.db` | Upload history, execution logs, API-use estimates |
| `management.db` | Searchable video records and playlist rollover routes |
| `ledger.csv` | CSV export of managed video records |
| `history_calendar.db` | Calendar counts, manual changes, notes, deletion events |
| `metadata_history.json` | Reusable metadata and suppressed values |
| `upload_limit_state.json` | Estimated upload-limit reset time |
| `~/Library/Caches/iPhoto2YouTube/PhotoLibraryVideos/` | Cached Photo Library exports and thumbnails |

YouTube API-derived records are pruned after 30 days during local application initialization. Calendar notes and metadata-history suppression remain local and are not uploaded.

## CLI

The app invokes `.venv/bin/iphoto2youtube`, which may also be used directly:

```bash
.venv/bin/iphoto2youtube auth-status
.venv/bin/iphoto2youtube history list --output json
.venv/bin/iphoto2youtube --help
```

The CLI supports OAuth, channel inspection, metadata rendering, single and manifest-based batch upload, history and run inspection, search, verification, metadata synchronization, controlled deletion, and backfill.

## Documents

- [仕様書](%E4%BB%95%E6%A7%98%E6%9B%B8.md)
- [技術説明書](%E6%8A%80%E8%A1%93%E8%AA%AC%E6%98%8E%E6%9B%B8.md)
- [YouTube API Usage Documentation](iPhoto2YouTube_API_Documentation.md)
- [Privacy Policy](Privacy%20Policy.md)
- [Terms of Service](Terms%20of%20Service.md)

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 HiroPublic.

This project was developed with assistance from generative AI.

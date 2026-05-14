# Local Video Uploader

## 1. Overview

Local Video Uploader is a macOS desktop application that allows users to upload videos from their local photo library to their own YouTube channel.

The application is designed for personal use and operates entirely through explicit user interaction.

### Related Documents

- [API Documentation](iPhoto2YouTube_API_Documentation.md): Overview of Local Video Uploader API integration and usage.
- [Privacy Policy](Privacy%20Policy.md): Privacy policy for the application.
- [Terms of Service](Terms%20of%20Service.md): Terms of service for the application.

---

## 2. Use of YouTube API Services

The application uses YouTube Data API for:

- Uploading videos (videos.insert)
- Setting metadata (title, description, tags, visibility)
- Assigning videos to playlists

The application does not access or process any data belonging to other users.

---

## 3. OAuth 2.0 Authentication Flow

1. User clicks "Sign in with Google"
2. Google OAuth consent screen is displayed
3. User grants permission
4. Application receives access token
5. API requests are executed on behalf of the user

No passwords are stored.

---

## 4. User Workflow

1. Launch application
2. Sign in with Google account
3. Select videos from local photo library
4. Edit metadata:
   - Title
   - Description
   - Tags
   - Visibility
   - Playlist
5. Click "Upload"
6. Confirm upload in dialog
7. Upload is executed via YouTube API

All actions are initiated by the user.

---

## 5. Data Handling

### Stored Data
- Video ID
- Title
- Upload date
- Metadata

Stored locally on user's device only.

### Authentication Data
- OAuth tokens stored locally
- Not shared externally
- No passwords stored

### Retention
YouTube API-derived data is retained for up to 30 days. Older API-derived records are automatically removed from local storage.

---

## 6. API Usage Characteristics

- No background processing
- No scheduled uploads
- No automation
- No scraping
- No bulk data collection

All API calls are user-initiated.

---

## 7. Security and Privacy

- Uses Google OAuth 2.0
- No third-party data sharing
- No external servers
- Users can revoke access anytime

---

## 8. Compliance

The application complies with YouTube API Services policies:

- Only accesses user-authorized data
- Uses minimal required data
- Provides full user control

---

## 9. Notes

- Desktop application (not a web service)
- Personal-use tool
- Fully user-controlled workflow

---

## 10. Configuration

The app reads user settings from `config.json` in the support directory.

Default path:

- `./.iphoto2youtube/config.json`

Related files:

- `src/iphoto2youtube_cli/config.py`: Defines available settings, default values, and how `config.json` is loaded.
- `config.example.json`: Example user-editable configuration file.
- `config.json`: The actual runtime configuration for your local environment.

How to change a setting:

1. Change `config.json` if you want to override the value for your local environment.
2. Change `src/iphoto2youtube_cli/config.py` if you want to change the application's built-in default.
3. Change `config.example.json` if you want the sample file to show the new recommended value.

Example:

```json
{
  "youtube_api_daily_quota_limit": 50000
}
```

If `youtube_api_daily_quota_limit` is omitted from `config.json`, the built-in default from `src/iphoto2youtube_cli/config.py` is used.

---

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Author

Copyright (c) 2026 HiroPublic

This project was developed with assistance from generative AI.

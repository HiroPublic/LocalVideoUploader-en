# iPhoto2YouTube

## 1. Overview

iPhoto2YouTube is a macOS desktop application that allows users to upload videos from their local photo library to their own YouTube channel.

The application is designed for personal use and operates entirely through explicit user interaction.

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
Data is kept only for application use and can be deleted by the user.

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


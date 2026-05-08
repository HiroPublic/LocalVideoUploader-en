# **Privacy Policy for Local Video Uploader**

**Last Updated:** April 22, 2026

## **1\. Introduction**

Local Video Uploader ("the Application") is a standalone, native macOS desktop application designed to help users upload their local photo library videos directly to their own YouTube channels.

Your privacy is critically important. The Application is built on the principle that your data belongs to you. Because it is a local desktop application, **no personal data, video content, or authentication credentials are ever transmitted to or stored on any external servers owned by the developer.** All operations occur locally on your machine and communicate directly with Google/YouTube API servers.

## **2\. YouTube API Services**

The Application utilizes YouTube API Services to authenticate you, retrieve your channel information, and upload videos on your behalf.

By using this Application, you are agreeing to be bound by the [**YouTube Terms of Service**](https://www.youtube.com/t/terms).

Furthermore, the use of YouTube API Services is subject to the [**Google Privacy Policy**](https://policies.google.com/privacy).

Please also review the application's [**Terms of Service**](https://github.com/HiroPublic/LocalVideoUploader-en/blob/main/Terms%20of%20Service.md).

## **3\. Data Collection and Usage**

### **What Data We Access**

When you authorize the Application via Google OAuth 2.0, the Application accesses:

* Basic profile information to identify your authenticated account.  
* YouTube Data API to insert (upload) videos, update metadata (titles, descriptions, tags, visibility), and manage playlists on your channel.

### **How Data is Stored**

* **Authentication Tokens:** OAuth 2.0 access and refresh tokens are stored securely and **locally** on your macOS device. They are strictly used to authenticate your requests to YouTube.  
* **Video Metadata & History:** Upload history and metadata templates are saved locally on your machine for your convenience.  
* **We do NOT collect, harvest, or transmit your data.** No analytics, tracking, or telemetry data is sent back to the developer.

### **Information Stored On Your Device**

Because this is a native desktop application, the Application stores and accesses limited information directly on your device in order to function. This includes:

* OAuth credential files stored locally on disk after you authorize the Application.
* Local SQLite database files and CSV files used to keep upload history, metadata templates, and app settings on your device.
* Temporary local files created while the Application is preparing uploads or processing metadata.

The Application does **not** use cookies, browser local storage, advertising identifiers, tracking pixels, or similar cross-site tracking technologies. The Application also does not allow third parties to place or read such tracking technologies through the Application.

YouTube API-derived data retained locally by the Application is automatically removed after 30 days unless it is refreshed through a new user-initiated API interaction.

## **4\. Data Sharing**

**We do not share your data.** Because all data is processed and stored locally on your device, the developer has no access to your Google account, your videos, or your personal information. Consequently, no data is shared with any third parties by the developer.

## **5\. Revoking Access**

You maintain complete control over your data and the Application's access to your Google Account.

You can revoke the Application's access to your data at any time via your Google Account security settings page at:

[**https://myaccount.google.com/permissions**](https://myaccount.google.com/permissions)

Revoking access will immediately prevent the Application from taking any further actions on your behalf until you re-authorize it.

## **6\. Contact Information**

If you have any questions or concerns regarding this Privacy Policy, please refer to the project's [GitHub Repository](https://github.com/HiroPublic/LocalVideoUploader-en) and open an issue.

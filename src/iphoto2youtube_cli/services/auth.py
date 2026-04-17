from __future__ import annotations

from pathlib import Path

from ..config import YOUTUBE_SCOPES
from ..exceptions import AuthError


class GoogleOAuthService:
    def __init__(self, credentials_file: Path, token_file: Path) -> None:
        self.credentials_file = credentials_file
        self.token_file = token_file

    def is_authenticated(self) -> bool:
        creds = self.load_cached_credentials(optional=True)
        return bool(creds and (creds.valid or (creds.expired and creds.refresh_token)))

    def load_cached_credentials(self, optional: bool = False):
        try:
            from google.oauth2.credentials import Credentials
        except ImportError as exc:
            raise AuthError(
                "Google OAuth ライブラリが未導入です。`pip install -e .` を実行してください。"
            ) from exc

        creds = None
        if self.token_file.exists():
            creds = Credentials.from_authorized_user_file(str(self.token_file), YOUTUBE_SCOPES)
        if creds:
            granted_scopes = set(creds.scopes or [])
            required_scopes = set(YOUTUBE_SCOPES)
            if not required_scopes.issubset(granted_scopes):
                if optional:
                    return None
                raise AuthError(
                    "OAuth 権限が古いため、この操作は実行できません。`auth-login` をやり直して権限を更新してください。"
                )
            return creds
        if optional:
            return None
        raise AuthError("有効な OAuth セッションがありません。`auth-login` を先に実行してください。")

    def load_credentials(self, optional: bool = False):
        try:
            from google.auth.transport.requests import Request
        except ImportError as exc:
            raise AuthError(
                "Google OAuth ライブラリが未導入です。`pip install -e .` を実行してください。"
            ) from exc

        creds = self.load_cached_credentials(optional=optional)
        if creds and creds.valid:
            return creds
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            self._save_credentials(creds)
        if creds and creds.valid:
            return creds
        if optional:
            return None
        raise AuthError("有効な OAuth セッションがありません。`auth-login` を先に実行してください。")

    def login(self):
        try:
            from google_auth_oauthlib.flow import InstalledAppFlow
        except ImportError as exc:
            raise AuthError(
                "Google OAuth ライブラリが未導入です。`pip install -e .` を実行してください。"
            ) from exc
        if not self.credentials_file.exists():
            raise AuthError(
                f"OAuth クライアント設定が見つかりません: {self.credentials_file}"
            )
        flow = InstalledAppFlow.from_client_secrets_file(
            str(self.credentials_file),
            scopes=YOUTUBE_SCOPES,
        )
        creds = flow.run_local_server(port=0)
        self._save_credentials(creds)
        return creds

    def logout(self) -> None:
        if self.token_file.exists():
            self.token_file.unlink()

    def _save_credentials(self, creds) -> None:
        self.token_file.parent.mkdir(parents=True, exist_ok=True)
        self.token_file.write_text(creds.to_json(), encoding="utf-8")

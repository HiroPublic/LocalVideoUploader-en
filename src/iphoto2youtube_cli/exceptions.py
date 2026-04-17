class CliError(Exception):
    """Base CLI error with a user-friendly message."""


class ValidationError(CliError):
    """Raised when CLI input is invalid."""


class AuthError(CliError):
    """Raised when OAuth authentication is unavailable or invalid."""


class UploadError(CliError):
    """Raised when YouTube upload steps fail."""


class YouTubeApiError(UploadError):
    """Raised when YouTube API returns a structured error."""

    def __init__(
        self,
        message: str,
        *,
        operation: str = "",
        category: str = "unknown",
        retryable: bool = False,
        status_code: int | None = None,
        reason: str = "",
    ) -> None:
        super().__init__(message)
        self.operation = operation
        self.category = category
        self.retryable = retryable
        self.status_code = status_code
        self.reason = reason


class CsvExportError(CliError):
    """Raised when CSV export fails."""

"""Stable cloud account identities independent of valve order or selection."""

from urllib.parse import urlsplit, urlunsplit


def normalize_hub_url(hub_url: str) -> str:
    """Treat the hub base URL and its SignalR endpoint as the same server."""
    parts = urlsplit(hub_url)
    path = parts.path.rstrip("/")
    if path.lower().endswith("/signalr"):
        path = path[:-8]
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower(), path, parts.query, "")
    )


def account_unique_id(hub_url: str, user_id: str | int) -> str:
    """Scope the cloud user ID to its server."""
    return f"{normalize_hub_url(hub_url)}::{user_id}"

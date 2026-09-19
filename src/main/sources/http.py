"""Minimal authenticated GitHub HTTP client (GraphQL + REST).

Transport is injectable for offline tests: ``GitHubClient.request_hook``
may be replaced by a callable with the same signature as ``_request``.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable
from typing import Any

import requests

GRAPHQL_URL = "https://api.github.com/graphql"
REST_BASE = "https://api.github.com"
TIMEOUT: tuple[float, float] = (10, 60)
MAX_RETRIES = 3


class ApiError(RuntimeError):
    """GitHub API error. Messages are scrubbed to never contain tokens."""


class NetworkError(ApiError):
    """Connection-level failure (DNS, timeout, ...)."""


def resolve_token(explicit: str | None = None) -> str | None:
    """PROFILE_PAT > GITHUB_TOKEN > none. Explicit argument wins."""
    if explicit:
        return explicit
    return os.environ.get("PROFILE_PAT") or os.environ.get("GITHUB_TOKEN") or None


def _scrub(text: str, token: str | None) -> str:
    if token:
        return text.replace(token, "***")
    return text


class GitHubClient:
    """Thin wrapper over the GitHub REST + GraphQL APIs."""

    def __init__(self, token: str | None) -> None:
        self.token = token
        self._session = requests.Session()
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Jason-skd-profile-gen",
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self._session.headers.update(headers)
        # Injectable for offline unit tests: (method, url, json) -> decoded JSON.
        self.request_hook: Callable[[str, str, dict[str, Any] | None], Any] | None = None

    def graphql(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        """POST a GraphQL query; returns the ``data`` member."""
        payload = self._request("POST", GRAPHQL_URL, json={"query": query, "variables": variables})
        data = dict(payload) if isinstance(payload, dict) else {}
        if "errors" in data:
            msgs = "; ".join(str(e.get("message", "?")) for e in data["errors"])
            raise ApiError(_scrub(f"GraphQL error: {msgs}", self.token))
        return dict(data.get("data") or {})

    def rest(self, path: str) -> Any:
        """GET a REST path (``/orgs/x`` or an absolute URL)."""
        url = path if path.startswith("http") else f"{REST_BASE}{path}"
        return self._request("GET", url)

    def _request(self, method: str, url: str, *, json: dict[str, Any] | None = None) -> Any:
        if self.request_hook is not None:
            return self.request_hook(method, url, json)
        last: Exception | None = None
        for attempt in range(MAX_RETRIES):
            try:
                resp = self._session.request(method, url, timeout=TIMEOUT, json=json)
            except requests.RequestException as exc:
                last = NetworkError(f"network failure: {type(exc).__name__}")
            else:
                if resp.status_code in (429,) or resp.status_code >= 500:
                    last = ApiError(f"HTTP {resp.status_code}")
                elif resp.status_code >= 400:
                    raise ApiError(
                        _scrub(f"HTTP {resp.status_code}: {resp.text[:300]}", self.token)
                    )
                else:
                    return resp.json()
            time.sleep(2**attempt)
        raise last if last else ApiError("request failed")

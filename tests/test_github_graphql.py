"""Unit tests: Channel 1 parsing + degradation paths (offline via request_hook)."""

from __future__ import annotations

from typing import Any

import pytest

from main.sources.github_graphql import empty_account, fetch_account
from main.sources.http import GitHubClient

from .helpers import build_user_payload, build_viewer_payload

TOKEN = "gho_test_fixture_token"


def test_parse_viewer_totals_and_days() -> None:
    client = GitHubClient(TOKEN)
    client.request_hook = lambda method, url, json: build_viewer_payload()

    account = fetch_account(
        client, "Jason-skd", from_iso="2025-09-07T00:00:00Z", to_iso="2026-09-07T00:00:00Z"
    )

    assert account.self_view is True
    assert account.contributions_total == 13  # 4+0+2+0+6+0+1
    assert account.commits == 538
    assert account.issues == 52
    assert account.pull_requests == 41
    assert account.reviews == 15
    assert account.new_repositories == 10
    assert account.public_sum == 656
    assert account.active_days == 4  # days with count > 0
    assert account.stars(private_too=True) == 10
    assert account.stars(private_too=False) == 7
    assert account.external_repos == ["awesome-dsh-plugin/awesome-dsh-plugin"]


def test_token_of_other_identity_falls_back_to_public_user_query() -> None:
    client = GitHubClient(TOKEN)
    calls: list[str] = []

    def hook(method: str, url: str, json: dict[str, Any] | None) -> dict[str, Any]:
        assert json is not None
        calls.append("user" if "user(login" in json["query"] else "viewer")
        if "user(login" in json["query"]:
            return build_user_payload()
        return build_viewer_payload(login="github-actions[bot]")

    client.request_hook = hook
    account = fetch_account(
        client, "Jason-skd", from_iso="2025-09-07T00:00:00Z", to_iso="2026-09-07T00:00:00Z"
    )

    assert calls == ["viewer", "user"]
    assert account.self_view is False
    assert account.notes == ["token is not the profile owner: public-only caliber"]
    assert account.restricted == 0


def test_no_token_degrades_to_empty_account() -> None:
    client = GitHubClient(None)
    account = fetch_account(client, "Jason-skd", from_iso="x", to_iso="y")

    assert account.contributions_total is None
    assert account.repos == []
    assert any("no token" in note for note in account.notes)


def test_empty_account_defaults() -> None:
    account = empty_account("Jason-skd", ["channel 1 failed: boom"])
    assert account.contributions_total is None
    assert account.stars(private_too=True) == 0
    assert account.public_sum is None


@pytest.mark.parametrize("pattern,expected", [([0] * 7, 0), ([1, 1, 1, 1, 1, 1, 1], 7)])
def test_active_day_counting(pattern: list[int], expected: int) -> None:
    client = GitHubClient(TOKEN)
    client.request_hook = lambda method, url, json: build_viewer_payload(calendar=pattern)
    account = fetch_account(client, "Jason-skd", from_iso="x", to_iso="y")
    assert account.active_days == expected

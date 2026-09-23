#!/usr/bin/env python3
"""Fail Release builds whose ANKR proxy configuration is unsafe or unresolved."""

from __future__ import annotations

import os
import sys
from collections.abc import Mapping
from urllib.parse import SplitResult, urlsplit


EXPECTED_PATHS = {
    "ANKR_MULTICHAIN_PROXY_URL": "/v1/provider/ankr/multichain",
    "ANKR_TRON_JSONRPC_PROXY_URL": "/v1/provider/ankr/tron/jsonrpc",
    "ANKR_TRON_REST_PROXY_BASE_URL": "/v1/provider/ankr/tron/rest",
    "ANKR_SOLANA_JSONRPC_PROXY_URL": "/v1/provider/ankr/solana/jsonrpc",
    "ANKR_XRP_JSONRPC_PROXY_URL": "/v1/provider/ankr/xrp/jsonrpc",
    "ANKR_NEAR_JSONRPC_PROXY_URL": "/v1/provider/ankr/near/jsonrpc",
}
BASE_URL_KEY = "NOTIFICATION_SERVICE_BASE_URL"


class ConfigurationError(ValueError):
    """A sanitized build-configuration failure safe for build logs."""


def _parsed_https_url(key: str, raw_value: str | None) -> SplitResult:
    value = (raw_value or "").strip()
    if not value:
        raise ConfigurationError(f"{key} is missing")
    if "$(" in value or "${" in value:
        raise ConfigurationError(f"{key} contains an unresolved build setting")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError(f"{key} is not a valid URL") from error
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise ConfigurationError(f"{key} must be an absolute HTTPS URL")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigurationError(f"{key} must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ConfigurationError(
            f"{key} must not contain a query or fragment"
        )
    if parsed.hostname.lower() == "rpc.ankr.com":
        raise ConfigurationError(
            f"{key} must use the app-owned proxy, not ANKR directly"
        )
    if port not in (None, 443):
        raise ConfigurationError(f"{key} must use the standard HTTPS port")
    return parsed


def _origin(parsed: SplitResult) -> tuple[str, str, int]:
    return (
        parsed.scheme.lower(),
        (parsed.hostname or "").lower(),
        parsed.port or 443,
    )


def validate_release_configuration(environment: Mapping[str, str]) -> None:
    """Validate resolved Release settings without exposing their values."""
    base = _parsed_https_url(
        BASE_URL_KEY,
        environment.get(BASE_URL_KEY),
    )
    if base.path not in ("", "/"):
        raise ConfigurationError(
            f"{BASE_URL_KEY} must not contain a path"
        )
    expected_origin = _origin(base)

    for key, expected_path in EXPECTED_PATHS.items():
        parsed = _parsed_https_url(key, environment.get(key))
        if _origin(parsed) != expected_origin:
            raise ConfigurationError(
                f"{key} must use the notification service origin"
            )
        if parsed.path != expected_path:
            raise ConfigurationError(
                f"{key} must use the checked-in proxy route"
            )


def main() -> int:
    if os.environ.get("CONFIGURATION") != "Release":
        return 0
    try:
        validate_release_configuration(os.environ)
    except ConfigurationError as error:
        print(f"error: Invalid Release ANKR configuration: {error}", file=sys.stderr)
        return 1
    print("Release ANKR proxy configuration validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Reject builds that would move Aperture into another Keychain namespace."""

from __future__ import annotations

import os
import plistlib
import re
import sys
from collections.abc import Mapping
from pathlib import Path


EXPECTED_TEAM_IDENTIFIER = "C5T44SZNQX"
EXPECTED_BUNDLE_IDENTIFIER = "com.aperture.wallet"
EXPECTED_ACCESS_GROUP = (
    "$(AppIdentifierPrefix)com.aperture.wallet"
)
EXPECTED_ENTITLEMENTS_PATH = "Oath/Oath.entitlements"


class ConfigurationError(ValueError):
    """A sanitized signing-configuration failure safe for build logs."""


def _required_setting(
    environment: Mapping[str, str],
    key: str,
) -> str:
    value = environment.get(key, "").strip()
    if not value:
        raise ConfigurationError(f"{key} is missing")
    if "$(" in value or "${" in value:
        raise ConfigurationError(f"{key} is unresolved")
    return value


def validate_signing_environment(
    environment: Mapping[str, str],
) -> None:
    team = _required_setting(environment, "DEVELOPMENT_TEAM")
    if team != EXPECTED_TEAM_IDENTIFIER:
        raise ConfigurationError(
            "DEVELOPMENT_TEAM does not match Aperture's stable signing team"
        )

    bundle = _required_setting(
        environment,
        "PRODUCT_BUNDLE_IDENTIFIER",
    )
    if bundle != EXPECTED_BUNDLE_IDENTIFIER:
        raise ConfigurationError(
            "PRODUCT_BUNDLE_IDENTIFIER does not match Aperture"
        )

    entitlements = _required_setting(
        environment,
        "CODE_SIGN_ENTITLEMENTS",
    )
    if entitlements != EXPECTED_ENTITLEMENTS_PATH:
        raise ConfigurationError(
            "CODE_SIGN_ENTITLEMENTS does not use Aperture's canonical file"
        )


def validate_entitlements(path: Path) -> None:
    try:
        with path.open("rb") as stream:
            entitlements = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ConfigurationError(
            "the canonical entitlements file could not be read"
        ) from error

    groups = entitlements.get("keychain-access-groups")
    if groups != [EXPECTED_ACCESS_GROUP]:
        raise ConfigurationError(
            "keychain-access-groups must contain only Aperture's stable group"
        )


def validate_swift_configuration(path: Path) -> None:
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ConfigurationError(
            "WalletKeychainConfiguration.swift could not be read"
        ) from error

    expected_values = {
        "teamIdentifier": EXPECTED_TEAM_IDENTIFIER,
        "applicationBundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
    }
    for name, expected in expected_values.items():
        pattern = rf'static let {name}\s*=\s*"{re.escape(expected)}"'
        if re.search(pattern, source) is None:
            raise ConfigurationError(
                f"{name} does not match the stable signing contract"
            )


def validate_build(
    environment: Mapping[str, str],
    source_root: Path,
) -> None:
    validate_signing_environment(environment)
    validate_entitlements(
        source_root / EXPECTED_ENTITLEMENTS_PATH
    )
    validate_swift_configuration(
        source_root
        / "Oath/Security/WalletKeychainConfiguration.swift"
    )


def main() -> int:
    source_root_value = os.environ.get("SRCROOT", "").strip()
    if not source_root_value:
        print(
            "error: Invalid Keychain signing configuration: SRCROOT is missing",
            file=sys.stderr,
        )
        return 1

    try:
        validate_build(os.environ, Path(source_root_value))
    except ConfigurationError as error:
        print(
            f"error: Invalid Keychain signing configuration: {error}",
            file=sys.stderr,
        )
        return 1

    print("Aperture Keychain signing configuration validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

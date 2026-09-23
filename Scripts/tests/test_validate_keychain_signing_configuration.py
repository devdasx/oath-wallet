from __future__ import annotations

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "validate_keychain_signing_configuration.py"
)
SPEC = importlib.util.spec_from_file_location(
    "validate_keychain_signing_configuration",
    SCRIPT_PATH,
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def valid_environment() -> dict[str, str]:
    return {
        "DEVELOPMENT_TEAM": MODULE.EXPECTED_TEAM_IDENTIFIER,
        "PRODUCT_BUNDLE_IDENTIFIER":
            MODULE.EXPECTED_BUNDLE_IDENTIFIER,
        "CODE_SIGN_ENTITLEMENTS":
            MODULE.EXPECTED_ENTITLEMENTS_PATH,
    }


class KeychainSigningConfigurationTests(unittest.TestCase):
    def test_accepts_stable_signing_environment(self) -> None:
        MODULE.validate_signing_environment(valid_environment())

    def test_rejects_another_development_team(self) -> None:
        environment = valid_environment()
        environment["DEVELOPMENT_TEAM"] = "DIFFERENT1"

        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "stable signing team",
        ):
            MODULE.validate_signing_environment(environment)

    def test_rejects_bundle_or_entitlements_override(self) -> None:
        environment = valid_environment()
        environment["PRODUCT_BUNDLE_IDENTIFIER"] = "example.wallet"
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "does not match Aperture",
        ):
            MODULE.validate_signing_environment(environment)

        environment = valid_environment()
        environment["CODE_SIGN_ENTITLEMENTS"] = "Other.entitlements"
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "canonical file",
        ):
            MODULE.validate_signing_environment(environment)

    def test_rejects_literal_team_qualified_access_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Entitlements.plist"
            with path.open("wb") as stream:
                plistlib.dump(
                    {
                        "keychain-access-groups": [
                            "C5T44SZNQX.com.aperture.wallet"
                        ]
                    },
                    stream,
                )

            with self.assertRaisesRegex(
                MODULE.ConfigurationError,
                "stable group",
            ):
                MODULE.validate_entitlements(path)

    def test_accepts_stable_app_identifier_prefix_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Entitlements.plist"
            with path.open("wb") as stream:
                plistlib.dump(
                    {
                        "keychain-access-groups": [
                            MODULE.EXPECTED_ACCESS_GROUP
                        ]
                    },
                    stream,
                )

            MODULE.validate_entitlements(path)


if __name__ == "__main__":
    unittest.main()

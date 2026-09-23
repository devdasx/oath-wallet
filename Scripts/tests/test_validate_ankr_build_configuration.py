from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "validate_ankr_build_configuration.py"
)
SPEC = importlib.util.spec_from_file_location(
    "validate_ankr_build_configuration",
    SCRIPT_PATH,
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def valid_environment() -> dict[str, str]:
    base = "https://aperture.example"
    return {
        "NOTIFICATION_SERVICE_BASE_URL": base,
        "ANKR_MULTICHAIN_PROXY_URL":
            f"{base}/v1/provider/ankr/multichain",
        "ANKR_TRON_JSONRPC_PROXY_URL":
            f"{base}/v1/provider/ankr/tron/jsonrpc",
        "ANKR_TRON_REST_PROXY_BASE_URL":
            f"{base}/v1/provider/ankr/tron/rest",
        "ANKR_SOLANA_JSONRPC_PROXY_URL":
            f"{base}/v1/provider/ankr/solana/jsonrpc",
        "ANKR_XRP_JSONRPC_PROXY_URL":
            f"{base}/v1/provider/ankr/xrp/jsonrpc",
    }


class ReleaseAnkrConfigurationTests(unittest.TestCase):
    def test_accepts_complete_app_owned_proxy_configuration(self) -> None:
        MODULE.validate_release_configuration(valid_environment())

    def test_rejects_missing_or_unresolved_settings(self) -> None:
        missing = valid_environment()
        del missing["ANKR_SOLANA_JSONRPC_PROXY_URL"]
        with self.assertRaisesRegex(MODULE.ConfigurationError, "is missing"):
            MODULE.validate_release_configuration(missing)

        unresolved = valid_environment()
        unresolved["ANKR_MULTICHAIN_PROXY_URL"] = (
            "$(NOTIFICATION_SERVICE_BASE_URL)/v1/provider/ankr/multichain"
        )
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "unresolved build setting",
        ):
            MODULE.validate_release_configuration(unresolved)

    def test_rejects_credentials_and_direct_ankr_urls(self) -> None:
        credentialed = valid_environment()
        credentialed["ANKR_MULTICHAIN_PROXY_URL"] = (
            "https://user:secret@aperture.example"
            "/v1/provider/ankr/multichain"
        )
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "must not contain credentials",
        ):
            MODULE.validate_release_configuration(credentialed)

        direct = valid_environment()
        direct["NOTIFICATION_SERVICE_BASE_URL"] = "https://rpc.ankr.com"
        direct["ANKR_MULTICHAIN_PROXY_URL"] = (
            "https://rpc.ankr.com/v1/provider/ankr/multichain"
        )
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "app-owned proxy",
        ):
            MODULE.validate_release_configuration(direct)

    def test_rejects_wrong_origin_or_route(self) -> None:
        wrong_origin = valid_environment()
        wrong_origin["ANKR_TRON_JSONRPC_PROXY_URL"] = (
            "https://other.example/v1/provider/ankr/tron/jsonrpc"
        )
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "notification service origin",
        ):
            MODULE.validate_release_configuration(wrong_origin)

        wrong_route = valid_environment()
        wrong_route["ANKR_SOLANA_JSONRPC_PROXY_URL"] = (
            "https://aperture.example/v1/provider/ankr/solana"
        )
        with self.assertRaisesRegex(
            MODULE.ConfigurationError,
            "checked-in proxy route",
        ):
            MODULE.validate_release_configuration(wrong_route)


if __name__ == "__main__":
    unittest.main()

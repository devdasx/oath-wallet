#!/usr/bin/env python3
"""Validate Aperture's localized App Intents and public navigation contract."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parents[2]
APP_DIRECTORY = WORKSPACE / "Oath"
WEBSITE_DIRECTORY = WORKSPACE / "Website"
APPLICATION_NAME_TOKEN = "${applicationName}"

ENTRY_POINTS = (
    (
        "Search in ${applicationName}",
        "wallet.search.start.title",
        "ApertureSearchWalletIntent",
        "universalSearch",
        "/app/search",
    ),
    (
        "Receive crypto in ${applicationName}",
        "receive.title",
        "ApertureReceiveCryptoIntent",
        "receive",
        "/app/receive",
    ),
    (
        "Convert currencies in ${applicationName}",
        "settings.converter.title",
        "ApertureCurrencyConverterIntent",
        "currencyConverter",
        "/app/tools/currency-converter",
    ),
    (
        "Open security settings in ${applicationName}",
        "settings.security.title",
        "ApertureSecuritySettingsIntent",
        "securitySettings",
        "/app/settings/security",
    ),
    (
        "Manage wallets in ${applicationName}",
        "settings.wallets.title",
        "ApertureWalletManagementIntent",
        "walletManagement",
        "/app/settings/wallets",
    ),
    (
        "Build a wallet with dice in ${applicationName}",
        "onboarding.creation.method.physical.title",
        "AperturePhysicalEntropyWalletIntent",
        "physicalEntropy",
        "/app/create-wallet/entropy",
    ),
)


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def shipped_locales() -> set[str]:
    return {
        path.name.removesuffix(".lproj")
        for path in APP_DIRECTORY.glob("*.lproj")
        if (path / "Localizable.strings").is_file()
    }


def localized_title(locale: str, key: str) -> str:
    strings_path = APP_DIRECTORY / f"{locale}.lproj" / "Localizable.strings"
    source = strings_path.read_text(encoding="utf-8")
    pattern = re.compile(
        rf'^"{re.escape(key)}"\s*=\s*"((?:\\.|[^"\\])*)";\s*$',
        re.MULTILINE,
    )
    match = pattern.search(source)
    if match is None:
        raise AssertionError(f"Missing {key!r} in {strings_path}")
    return json.loads(f'"{match.group(1)}"')


class AgentAppIntentContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = load_json(APP_DIRECTORY / "AppShortcuts.xcstrings")
        cls.entry_contract = load_json(
            WEBSITE_DIRECTORY / "data/app-entry-points.json"
        )
        cls.aasa = load_json(
            WEBSITE_DIRECTORY
            / ".well-known/apple-app-site-association"
        )
        cls.intent_source = (
            APP_DIRECTORY / "OathAppIntents.swift"
        ).read_text(encoding="utf-8")
        cls.deep_link_source = (
            APP_DIRECTORY / "WalletEntropyEventDeepLink.swift"
        ).read_text(encoding="utf-8")
        cls.presentation_source = (
            APP_DIRECTORY / "Home/AppRootAgentDeepLinkRouting.swift"
        ).read_text(encoding="utf-8")

    def test_shortcut_catalog_covers_every_shipped_locale(self) -> None:
        locales = shipped_locales()
        self.assertEqual(len(locales), 57)
        self.assertEqual(self.catalog["sourceLanguage"], "en")
        self.assertEqual(set(self.catalog["strings"]), {
            phrase for phrase, _, _, _, _ in ENTRY_POINTS
        })

        for phrase, title_key, _, _, _ in ENTRY_POINTS:
            localizations = self.catalog["strings"][phrase]["localizations"]
            self.assertEqual(set(localizations), locales)
            for locale, localization in localizations.items():
                unit = localization["stringUnit"]
                self.assertEqual(unit["state"], "translated")
                value = unit["value"]
                self.assertEqual(value.count(APPLICATION_NAME_TOKEN), 1)
                expected = (
                    phrase
                    if locale == "en"
                    else f"{APPLICATION_NAME_TOKEN}: "
                    f"{localized_title(locale, title_key)}"
                )
                self.assertEqual(value, expected)

    def test_swift_intents_match_the_machine_contract(self) -> None:
        by_intent = {
            item["app_intent"]: item
            for item in self.entry_contract["entry_points"]
        }
        self.assertEqual(len(by_intent), len(ENTRY_POINTS))

        for phrase, _, intent, destination, path in ENTRY_POINTS:
            self.assertIn(f"struct {intent}: ApertureOpenAppIntent", self.intent_source)
            self.assertRegex(
                self.intent_source,
                rf"struct {intent}:[\s\S]*?"
                rf"static let destination = "
                rf"WalletAppDeepLinkDestination\.{destination}",
            )
            swift_phrase = phrase.replace(
                APPLICATION_NAME_TOKEN,
                r"\(.applicationName)",
            )
            self.assertIn(f'"{swift_phrase}"', self.intent_source)
            self.assertEqual(by_intent[intent]["path"], path)
            self.assertEqual(by_intent[intent]["url"], f"https://aperturex.io{path}")
            self.assertEqual(by_intent[intent]["app_destination"], destination)

    def test_parser_maps_only_declared_safe_routes(self) -> None:
        for _, _, _, destination, path in ENTRY_POINTS:
            self.assertIn(f'"{path}": .{destination}', self.deep_link_source)

        for forbidden in (
            "/app/send",
            "/app/sign",
            "/app/broadcast",
            "/app/import/private-key",
            "/app/export",
            "/app/delete-wallet",
        ):
            self.assertNotIn(forbidden, self.deep_link_source)
            self.assertNotIn(forbidden, json.dumps(self.entry_contract))

    def test_navigation_preserves_existing_security_gates(self) -> None:
        for required_gate in (
            "walletIsVisible",
            "sceneIsActive",
            "walletIsRestricted",
            "hasBlockingPresentation",
        ):
            self.assertIn(required_gate, self.presentation_source)
        self.assertRegex(
            self.presentation_source,
            r"walletIsVisible[\s\S]*sceneIsActive[\s\S]*"
            r"!walletIsRestricted[\s\S]*!hasBlockingPresentation",
        )
        self.assertNotRegex(
            self.presentation_source,
            r"sign|broadcast|privateKey|recoveryPhrase",
        )

    def test_public_association_tracks_the_current_release(self) -> None:
        associated_paths = [
            component["/"]
            for detail in self.aasa["applinks"]["details"]
            for component in detail["components"]
        ]
        policy = self.entry_contract["public_association_policy"]
        self.assertEqual(associated_paths, policy["active_paths"])
        self.assertTrue(set(associated_paths).isdisjoint(policy["pending_paths"]))

    def test_web_fallback_and_xcode_resources_are_wired(self) -> None:
        rewrites = (WEBSITE_DIRECTORY / ".htaccess").read_text(encoding="utf-8")
        self.assertIn("RewriteRule ^app(?:/.*)?$ app/index.php", rewrites)
        self.assertTrue((WEBSITE_DIRECTORY / "app/index.php").is_file())

        project = (
            WORKSPACE / "Oath.xcodeproj/project.pbxproj"
        ).read_text(encoding="utf-8")
        self.assertIn("AppShortcuts.xcstrings in Resources", project)
        for source_file in (
            "OathAppIntents.swift",
            "AppRootAgentDeepLinkRouting.swift",
        ):
            self.assertIn(f"{source_file} in Sources", project)


if __name__ == "__main__":
    unittest.main(verbosity=2)

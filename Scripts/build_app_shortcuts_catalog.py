#!/usr/bin/env python3
"""Build the localized App Shortcuts phrase catalog from shipped app titles."""

from __future__ import annotations

import json
import re
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parents[1]
APP_DIRECTORY = WORKSPACE / "EVMWallet"
OUTPUT_PATH = APP_DIRECTORY / "AppShortcuts.xcstrings"
APPLICATION_NAME_TOKEN = "${applicationName}"

PHRASES = (
    ("Search in ${applicationName}", "wallet.search.start.title"),
    ("Receive crypto in ${applicationName}", "receive.title"),
    ("Convert currencies in ${applicationName}", "settings.converter.title"),
    ("Open security settings in ${applicationName}", "settings.security.title"),
    ("Manage wallets in ${applicationName}", "settings.wallets.title"),
    (
        "Build a wallet with dice in ${applicationName}",
        "onboarding.creation.method.physical.title",
    ),
)


def shipped_locales() -> list[str]:
    return sorted(
        path.name.removesuffix(".lproj")
        for path in APP_DIRECTORY.glob("*.lproj")
        if (path / "Localizable.strings").is_file()
    )


def localized_title(locale: str, key: str) -> str:
    strings_path = APP_DIRECTORY / f"{locale}.lproj" / "Localizable.strings"
    source = strings_path.read_text(encoding="utf-8")
    pattern = re.compile(
        rf'^"{re.escape(key)}"\s*=\s*"((?:\\.|[^"\\])*)";\s*$',
        re.MULTILINE,
    )
    match = pattern.search(source)
    if match is None:
        raise RuntimeError(f"Missing {key!r} in {strings_path}")
    return json.loads(f'"{match.group(1)}"')


def build_catalog() -> dict[str, object]:
    locales = shipped_locales()
    if "en" not in locales:
        raise RuntimeError("The English localization is required.")

    strings: dict[str, object] = {}
    for source_phrase, title_key in PHRASES:
        localizations: dict[str, object] = {}
        for locale in locales:
            if locale == "en":
                value = source_phrase
            else:
                # A label-style spoken phrase is grammatical across every shipped
                # locale and reuses the app's reviewed, human-readable action title.
                value = f"{APPLICATION_NAME_TOKEN}: {localized_title(locale, title_key)}"
            localizations[locale] = {
                "stringUnit": {
                    "state": "translated",
                    "value": value,
                }
            }
        strings[source_phrase] = {"localizations": localizations}

    return {
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.1",
    }


def main() -> None:
    OUTPUT_PATH.write_text(
        json.dumps(build_catalog(), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {OUTPUT_PATH}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Offline source-catalog guard. No simulator, network, or application launch.

A passing audit proves structural completeness, not native-speaker quality.
Shared spellings must be reviewed in Design/Localization/shared-values.json;
never use that file to accept untranslated sentences.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = ("Localizable", "InfoPlist", "LanguageNames")
PERMISSIONS = {"NSCameraUsageDescription", "NSFaceIDUsageDescription"}
# Extracted formatting/branding values contain no translatable app copy.
INVARIANT_EXTRACTIONS = {"(%@)", "••••", "Permit2"}
FORMAT = re.compile(r"%(?:(\d+)\$)?([-+#0 ']*)(\d+|\*(?:\d+\$)?)?(?:\.(\d+|\*(?:\d+\$)?))?(hh|ll|[hlLjztq])?([@diuoxXfFeEgGaAcCsSp])|%%")
LINK = re.compile(r"\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)")
URL = re.compile(r"https?://[^\s)<>]+")
# This is the actual on-disk backup location. Translating its folder names
# would send users looking for directories the app does not create.
INVARIANT_PATHS = ("iCloud Drive › Oath Wallet › Wallet Backups",)
# Keep canonical names intact inside translated prose. A native grammatical
# suffix may follow the name (for example Finnish iCloudiin), but the name
# itself, including spaces in XRP Ledger, must retain its English spelling.
BRANDS = re.compile(
    r'\b(?:Oath|OATH|iCloud(?: Drive)?|iPhone|iPad|Face ID|Touch ID|WalletConnect|'
    r'THORChain|Bitcoin(?: Cash)?|Ethereum|Solana|Stellar|TRON|NEAR(?: Protocol)?|'
    r'Sui(?: Network)?|Aptos|Dogecoin|Litecoin|XRP Ledger|BNB Smart Chain|'
    r'Arbitrum|Avalanche|Arc|Base(?![0-9])|Fantom|Flare|Gnosis|Linea|Optimism|Polygon|'
    r'Celo\b|Monad|Unichain|HyperEVM|Robinhood Chain|Scroll|Somnia|Story|Taiko|Telos|'
    r'X Layer|Gram|BTC|ETH|SOL|TRX|XRP|XLM|USDT|USDC|RUNE|GRAM|BNB|BCH|'
    r'DOGE|LTC|TRC-20|ERC-20|SPL|Token-2022|Electrum|TrustedCoin|aezeed|'
    r'Safe|Squads|Ed25519|AIP-80|BIP-39|BIP39|WIF|Base58|Base64|JSON|MPT|'
    r'secp256k1|suiprivkey(?:1)?)\b', re.ASCII)
INFLECTED_BRANDS = re.compile(BRANDS.pattern[:-2], re.ASCII)


def normalized(value: str) -> str:
    # Directional isolation and spacing are presentation, not translations.
    # Ignore invisible format/variation characters only for visible-content
    # comparison; the original value still passes structural safety checks.
    canonical = unicodedata.normalize("NFKC", value)
    visible = "".join(c for c in canonical if unicodedata.category(c) != "Cf"
                      and not (0xFE00 <= ord(c) <= 0xFE0F or 0xE0100 <= ord(c) <= 0xE01EF))
    return " ".join(visible.split()).casefold()


def placeholders(value: str) -> Counter:
    """Compare argument position/type, allowing valid positional reordering."""
    result = Counter()
    position = 1
    for match in FORMAT.finditer(value):
        if match[0] == "%%":
            continue
        explicit, _flags, width, precision, length, kind = match.groups()
        shapes = []
        for star in (width, precision):
            if star and star.startswith("*"):
                star_index = position if star == "*" else int(star[1:-1])
                result[(star_index, "int")] += 1
                shapes.append(("*", star_index))
                if star == "*":
                    position += 1
            else:
                shapes.append(star)
        index = int(explicit) if explicit else position
        # Width/precision/flags and indexed star identity survive translation.
        result[(index, (length or "") + kind, _flags, *shapes)] += 1
        if not explicit:
            position += 1
    return result


def structure_errors(source: str, value: str, *, allow_bidi_additions: bool = False) -> list[str]:
    """Safety properties independent of language; no linguistic-quality claim."""
    errors = []
    if Counter(BRANDS.findall(source)) != Counter(INFLECTED_BRANDS.findall(value)):
        errors.append("invariant brand or network name changed")
    if placeholders(value) != placeholders(source):
        errors.append("format argument mismatch")
    if value.count("%%") != source.count("%%"):
        errors.append("escaped percent changed")
    # A new malformed conversion can become unsafe when String(format:) runs.
    if FORMAT.sub("", value).count("%") != FORMAT.sub("", source).count("%"):
        errors.append("unrecognized percent conversion changed")
    escapes = re.compile(r'\\(?:[nrt"\\]|u[0-9a-fA-F]{4})')
    if Counter(escapes.findall(value)) != Counter(escapes.findall(source)):
        errors.append("literal escape changed")
    if Counter(LINK.findall(value)) != Counter(LINK.findall(source)):
        errors.append("markdown link destinations changed")
    if Counter(URL.findall(value)) != Counter(URL.findall(source)):
        errors.append("URL destinations changed")
    for path in INVARIANT_PATHS:
        if source.count(path) != value.count(path):
            errors.append("backup folder path changed")
    safe_controls = "\u2066\u2067\u2068\u2069\u200e\u200f"
    unsafe_controls = "\u202a\u202b\u202c\u202d\u202e"
    if any(source.count(c) != value.count(c) for c in unsafe_controls):
        errors.append("bidirectional override changed")
    if any((value.count(c) < source.count(c) if allow_bidi_additions else value.count(c) != source.count(c)) for c in safe_controls):
        errors.append("bidirectional control changed")
    depth = 0
    for char in value:
        if char in "\u2066\u2067\u2068":
            depth += 1
        elif char == "\u2069":
            depth -= 1
            if depth < 0:
                break
    if depth:
        errors.append("unbalanced bidirectional isolation")
    if source.count("\n") != value.count("\n"):
        errors.append("paragraph layout changed")
    if re.search(r"⟦\s*[PK]\s*\d+\s*⟧", value):
        errors.append("unrestored translation token")
    return errors


def string_units(value: dict, path: str = "") -> dict[str, dict]:
    """Read plain and plural/device variation units without silently ignoring any."""
    found = {}
    if "stringUnit" in value:
        found[path or "value"] = value["stringUnit"]
    for group, variants in value.get("variations", {}).items():
        for variant, child in variants.items():
            found.update(string_units(child, f"{path}/{group}/{variant}"))
    return found


def source_keys(source: str) -> set[str]:
    keys = set()
    for line in source.splitlines():
        match = re.match(r"\s*case\s+(.+)", line)
        if match:
            for item in match[1].split(","):
                declaration = item.strip().split("=", 1)
                keys.add(declaration[-1].strip().strip('"'))
    return keys


def audit_catalog(name: str, catalog: dict, locales: set[str], shared: dict | None = None) -> list[str]:
    errors = []
    shared = shared or {}
    if catalog.get("sourceLanguage") != "en":
        errors.append(f"{name}: development language must be en")
    for key, entry in catalog.get("strings", {}).items():
        location = f"{name}/{key}"
        invariant = entry.get("shouldTranslate") is False
        if name == "InfoPlist" and key not in PERMISSIONS:
            continue  # Bundle names are invariant branding, not permission prose.
        if name == "Localizable" and key in INVARIANT_EXTRACTIONS and not entry.get("localizations"):
            continue
        translations = entry.get("localizations", {})
        unexpected = set(translations) - locales
        if unexpected:
            errors.append(f"{location}: unsupported locales {sorted(unexpected)}")
        if invariant:
            continue
        missing = locales - set(translations)
        if missing:
            errors.append(f"{location}: missing locales {sorted(missing)}")
        english_units = string_units(translations.get("en", {}))
        if not english_units:
            errors.append(f"{location}: missing English string unit")
        for locale, translation in translations.items():
            units = string_units(translation)
            if not units:
                errors.append(f"{location}/{locale}: missing string unit")
            for variant, unit in units.items():
                here = f"{location}/{locale}/{variant}"
                value = unit.get("value")
                if not isinstance(value, str) or not normalized(value):
                    errors.append(f"{here}: empty value")
                    continue
                if unit.get("state") != "translated":
                    errors.append(f"{here}: state is {unit.get('state')!r}, expected translated")
                english = english_units.get(variant) or english_units.get("value") or english_units.get("/plural/other")
                if not english:
                    errors.append(f"{here}: no corresponding English unit")
                    continue
                source = english.get("value", "")
                for issue in structure_errors(source, value, allow_bidi_additions=True):
                    errors.append(f"{here}: {issue}")
                if locale != "en" and normalized(value) == normalized(source):
                    # Formatting-only values and genuinely invariant technical names
                    # need no linguistic translation. All lexical copy does.
                    lexical = FORMAT.sub("", source)
                    if not any(c.isalpha() for c in lexical):
                        continue
                    reason = shared.get(key, {}).get(locale)
                    if not isinstance(reason, str) or not reason.strip():
                        errors.append(f"{here}: identical to English without a reviewed shared-spelling reason")
    return errors


def audit(root: Path) -> tuple[list[str], dict]:
    registry = json.loads((root / "Design/Localization/languages.json").read_text())
    locales = {entry["code"] for entry in registry}
    errors = []
    if len(registry) != 57 or len(locales) != len(registry) or "en" not in locales:
        errors.append("Registry must contain exactly 57 unique supported languages, including English")
    shared_path = root / "Design/Localization/shared-values.json"
    shared = json.loads(shared_path.read_text()) if shared_path.exists() else {}
    totals = {}
    for name in CATALOGS:
        data = json.loads((root / f"OathApp/Resources/{name}.xcstrings").read_text())
        errors.extend(audit_catalog(name, data, locales, shared.get(name, {})))
        totals[name] = {"keys": len(data["strings"]), "locales": len(locales)}
        if name == "Localizable":
            required = source_keys((root / "OathAtmosphere/Localization/OathStringKey.swift").read_text())
            for key in sorted(required - set(data["strings"])):
                errors.append(f"Localizable/{key}: OathStringKey has no catalog entry")
        if name == "InfoPlist":
            for key in sorted(PERMISSIONS - set(data["strings"])):
                errors.append(f"InfoPlist/{key}: missing permission description")
        if name == "LanguageNames":
            expected = {entry["nameKey"] for entry in registry}
            if set(data["strings"]) != expected:
                errors.append("LanguageNames: entries must exactly match registry name keys")
        for key, exceptions in shared.get(name, {}).items():
            if key not in data["strings"]:
                errors.append(f"{name}/{key}: stale shared-spelling exception")
            for locale, reason in exceptions.items():
                if locale == "en" or locale not in locales or not isinstance(reason, str) or not reason.strip():
                    errors.append(f"{name}/{key}/{locale}: invalid shared-spelling exception")
    return errors, totals


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json", action="store_true", help="Emit complete machine-readable findings")
    args = parser.parse_args()
    errors, totals = audit(args.root)
    if args.json:
        print(json.dumps({"catalogs": totals, "errors": errors}, ensure_ascii=False, indent=2))
    else:
        for error in errors[:100]:
            print(error)
        if len(errors) > 100:
            print(f"... {len(errors) - 100} more findings; use --json for all findings")
        print(f"Localization catalog audit: {len(errors)} findings across {len(totals)} catalogs.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())

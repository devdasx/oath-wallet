#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import plistlib
import re
import runpy
import sys
from collections import Counter


ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_DIRECTORY = ROOT / "EVMWallet"
INFO_PLIST = APP_DIRECTORY / "Info.plist"
EN_AUDIT = runpy.run_path(
    str(APP_DIRECTORY / "l10n" / "audit_en_keys.py")
)
ARCHIVED_ENGLISH_VALUES = EN_AUDIT["historical_old_values"](
    EN_AUDIT["load_json"](EN_AUDIT["MEMORY"]) or {}, "localizable"
)
REQUIRED_PERMISSION_KEYS = (
    "NSCameraUsageDescription",
    "NSFaceIDUsageDescription",
)
LOCALIZABLE_FILENAME = "Localizable.strings"
ENTRY_PATTERN = re.compile(
    r'^\s*"(?P<key>[^"]+)"\s*=\s*"(?P<value>(?:[^"\\]|\\.)*)"\s*;',
    re.MULTILINE,
)
FORMAT_ARGUMENT_PATTERN = re.compile(
    r"%(?:\d+\$)?(?:@|lld|ld|d|f|s)"
)
LOCALIZATION_KEY_PATTERN = (
    r"(?P<key>(?:[a-z][a-z0-9_]*\.)+[a-zA-Z0-9_%-]+)"
)
SWIFT_LOCALIZATION_PATTERNS = (
    re.compile(
        r"\b(?:Text|Button|Label|LabeledContent|Toggle|TextField|"
        r"SecureField|ContentUnavailableView|Picker|Section|Menu|"
        r"GroupBox|DisclosureGroup|NavigationLink|ShareLink)\(\s*\""
        + LOCALIZATION_KEY_PATTERN
        + r"\"",
        re.DOTALL,
    ),
    re.compile(
        r"\.(?:navigationTitle|accessibilityLabel|accessibilityHint|"
        r"accessibilityValue|help|alert|confirmationDialog)"
        r"\(\s*\""
        + LOCALIZATION_KEY_PATTERN
        + r"\"",
        re.DOTALL,
    ),
    re.compile(
        r"\b(?:WalletLocalization\.string|EnglishNumbers\.localized)"
        r"\(\s*\"" + LOCALIZATION_KEY_PATTERN + r"\"",
        re.DOTALL,
    ),
    re.compile(
        r"\b(?:PrimaryWalletButton|SecondaryWalletButton)"
        r"\(\s*title:\s*\"" + LOCALIZATION_KEY_PATTERN + r"\"",
        re.DOTALL,
    ),
    re.compile(
        r"\b(?:String\(localized:|LocalizedStringKey\(|LocalizedStringResource\()\s*\""
        + LOCALIZATION_KEY_PATTERN
        + r"\"",
        re.DOTALL,
    ),
)
SWIFT_ENGLISH_FALLBACK_PATTERN = re.compile(
    r"\b(?:WalletLocalization\.string|EnglishNumbers\.localized)"
    r"\(\s*\"" + LOCALIZATION_KEY_PATTERN + r"\"",
    re.DOTALL,
)
SWIFT_DIRECT_LOCALIZATION_PATTERNS = (
    SWIFT_LOCALIZATION_PATTERNS[0],
    SWIFT_LOCALIZATION_PATTERNS[1],
    SWIFT_LOCALIZATION_PATTERNS[3],
    SWIFT_LOCALIZATION_PATTERNS[4],
)
SWIFT_DIRECT_UI_LITERAL_PATTERNS = (
    re.compile(
        r"\b(?:Text|Button|Label|LabeledContent|Toggle|TextField|"
        r"SecureField|ContentUnavailableView|Picker|Section|Menu|"
        r"GroupBox|DisclosureGroup|NavigationLink|ShareLink)\(\s*\""
        r"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
    re.compile(
        r"\.(?:navigationTitle|accessibilityLabel|accessibilityHint|"
        r"accessibilityValue|help|alert|confirmationDialog)"
        r"\(\s*\"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
    re.compile(
        r"\b(?:String\(localized:|LocalizedStringKey\(|LocalizedStringResource\()\s*\""
        r"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
    re.compile(
        r"\bText\(\s*verbatim:\s*\""
        r"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
    re.compile(
        r"\b(?:PrimaryWalletButton|SecondaryWalletButton|"
        r"WalletAuthenticationFullScreenContainer)\(\s*"
        r"title:\s*\"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
)
# UIKit bridges must follow the same localization rules as SwiftUI views.
SWIFT_DIRECT_UI_LITERAL_PATTERNS += (
    re.compile(
        r"\b(?:UIAlertController|UIAlertAction|UIAction|UIBarButtonItem)"
        r"\(\s*title:\s*\"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
    re.compile(
        r"\.(?:text|placeholder|accessibilityLabel|accessibilityHint|accessibilityValue)"
        r"\s*=\s*\"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
    re.compile(
        r"\.setTitle\(\s*\"(?P<literal>(?:[^\"\\]|\\.)*)\"",
        re.DOTALL,
    ),
)
SEND_LITERAL_PATTERN = re.compile(
    r"\"(?P<key>(?:send|common)\.[^\"\n]+)\""
)
SENTENCE_TERMINATORS = (".", "!", "?", "…", "।", "。", "！", "？")
TOKEN_BOUNDARY_PUNCTUATION = (
    ".,;:!?()[]{}<>«»“”„‟'\"،؛؟。！？।|"
)
ADJACENT_DUPLICATE_ALLOWLIST = frozenset(
    {
        # Natural reduplication meaning "separately", not duplicated copy.
        ("sd", "bitcoin.settings.branches.footer", "الڳ"),
        ("ur", "bitcoin.settings.branches.footer", "الگ"),
        (
            "bn",
            "settings.security.auto_lock.immediately",
            "সঙ্গে",
        ),
        ("de", "settings.reset.icloud_preserved.message", "sie"),
        ("kn", "wallet.creation.passphrase.footer", "ಬೇರೆ"),
        ("ml", "device_migration.status.waiting.detail", "iphone-ൽ"),
        (
            "or",
            "settings.security.auto_lock.immediately",
            "ସଙ୍ଗେ",
        ),
        ("si", "send.network_fee.remembered.footer", "එක්"),
        ("si", "settings.reset.learn_more.backup.message", "එක්"),
        ("si", "wallet.creation.verification.message", "එක්"),
        ("si", "wallet.activity.filter.amount.footer", "එක්"),
        ("sw", "send.coin_control.error.duplicate_output", "lile"),
        (
            "vi",
            "wallet.transaction.details.notes.error.database_write",
            "ghi",
        ),
        (
            "vi",
            "settings.wallets.private_key.export.derivation_path",
            "dẫn",
        ),
        (
            "vi",
            "settings.wallets.private_key.export.selection.footer",
            "dẫn",
        ),
        ("vi", "device_migration.export.complete.detail", "toàn"),
    }
)
ADJACENT_PHRASE_DUPLICATE_ALLOWLIST = frozenset(
    {
        ("hi", "send.submit.error.solana_recipient_rent", "से कम"),
    }
)
COMPACT_LABEL_MAX_WORDS = {
    "send.notes.add.action": 3,
    "wallet.home.assets.pinned.title": 6,
    "wallet.home.assets.pin.action": 2,
    "wallet.home.assets.unpin.action": 3,
    "wallet.home.assets.hide.action": 2,
    "common.search.empty.title": 4,
    "security.unavailable.title": 6,
    "import.recovery.word_list.words.section": 3,
    "import.icloud.backup.type": 4,
    "import.icloud.backup.passphrase_wallet": 6,
    "import.recovery.options.toolbar": 7,
    "import.icloud.protection.keychain": 11,
}
REQUIRED_EXACT_LOCALIZED_VALUES = {
    ("ar", "send.notes.add.action"): "أضف ملاحظة",
    ("ar", "bitcoin.settings.balance"): "الرصيد",
    ("ar", "bitcoin.settings.branch.external"): "عناوين الاستلام",
    ("ar", "bitcoin.settings.branch.change"): "عناوين الباقي",
}
# Regressions confirmed by reviewing the English source and production screen.
# Exact source/key/value scope preserves legitimate uses such as balanced dice.
CONTEXTUAL_TRANSLATION_ERRORS = {
    ("ar", "bitcoin.settings.balance", "Balance"): "التوازن",
    ("bn", "bitcoin.settings.balance", "Balance"): "ভারসাম্য",
    ("cs", "bitcoin.settings.balance", "Balance"): "Rovnováha",
    ("de", "bitcoin.settings.balance", "Balance"): "Gleichgewicht",
    ("el", "bitcoin.settings.balance", "Balance"): "Ισορροπία",
    ("fa", "bitcoin.settings.balance", "Balance"): "تعادل",
    ("fi", "bitcoin.settings.balance", "Balance"): "Tasapaino",
    ("gu", "bitcoin.settings.balance", "Balance"): "સંતુલન",
    ("he", "bitcoin.settings.balance", "Balance"): "איזון",
    ("hi", "bitcoin.settings.balance", "Balance"): "संतुलन",
    ("hr", "bitcoin.settings.balance", "Balance"): "Ravnoteža",
    ("id", "bitcoin.settings.balance", "Balance"): "Keseimbangan",
    ("it", "bitcoin.settings.balance", "Balance"): "Equilibrio",
    ("km", "bitcoin.settings.balance", "Balance"): "តុល្យភាព",
    ("kn", "bitcoin.settings.balance", "Balance"): "ಸಮತೋಲನ",
    ("ne", "bitcoin.settings.balance", "Balance"): "सन्तुलन",
    ("or", "bitcoin.settings.balance", "Balance"): "ସନ୍ତୁଳନ",
    ("pa", "bitcoin.settings.balance", "Balance"): "ਸੰਤੁਲਨ",
    ("pl", "bitcoin.settings.balance", "Balance"): "Równowaga",
    ("pt-BR", "bitcoin.settings.balance", "Balance"): "Equilíbrio",
    ("pt-PT", "bitcoin.settings.balance", "Balance"): "Equilíbrio",
    ("ro", "bitcoin.settings.balance", "Balance"): "Echilibru",
    ("sl", "bitcoin.settings.balance", "Balance"): "Ravnovesje",
    ("sw", "bitcoin.settings.balance", "Balance"): "Mizani",
    ("ur", "bitcoin.settings.balance", "Balance"): "توازن",
    ("zh-Hans", "bitcoin.settings.balance", "Balance"): "平衡",
    ("zh-Hant", "bitcoin.settings.balance", "Balance"): "平衡",
    ("hr", "wallet.home.balance.hidden", "Balance Is Hidden"): "Ravnoteža je skrivena",
    ("ja", "bitcoin.settings.address.status.used", "Used"): "中古品",
    ("ko", "bitcoin.settings.address.status.used", "Used"): "중고",
    ("ru", "bitcoin.settings.address.status.used", "Used"): "Б/у",
    ("uk", "bitcoin.settings.address.status.used", "Used"): "б/в",
    ("zh-Hans", "bitcoin.settings.address.status.used", "Used"): "二手",
    ("zh-Hant", "bitcoin.settings.address.status.used", "Used"): "二手",
}
SAME_AS_ENGLISH_TRANSLATION_ALLOWLIST = frozenset(
    {
        # "Status" is the native spelling in these languages, not a fallback.
        ("da", "wallet.transaction.details.status"),
        ("de", "wallet.transaction.details.status"),
        ("hr", "wallet.transaction.details.status"),
        ("id", "wallet.transaction.details.status"),
        ("ms", "wallet.transaction.details.status"),
        ("ms", "import.private_key.action.import"),  # "Import" is the Malay action verb.
        ("nb", "wallet.transaction.details.status"),
        ("nl", "wallet.transaction.details.status"),
        ("pl", "wallet.transaction.details.status"),
        ("pt-BR", "wallet.transaction.details.status"),
        ("sv", "wallet.transaction.details.status"),
        ("da", "common.scan"),
        ("da", "wallet.home.action.send"),
        ("da", "wallet.home.action.scan"),
        ("da", "wallet.home.action.scan_qr_code"),
        ("da", "settings.appearance.system"),
        ("da", "send.title"),
        ("de", "wallet.transaction.details.token"),
        ("de", "settings.wallets.details.name"),
        ("de", "settings.appearance.system"),
        ("de", "smart_scanner.review.value.token"),
        ("es", "accessibility.error.format"),
        ("fr", "settings.notifications.title"),
        ("fr", "send.amount.max_action"),
        ("it", "wallet.transaction.details.token"),
        ("it", "smart_scanner.review.value.token"),
        ("it", "send.amount.max_action"),
        ("nb", "settings.appearance.system"),
        ("nb", "wallet.home.action.send"),
        ("pl", "settings.appearance.system"),
        ("sv", "settings.appearance.system"),
        ("sv", "send.amount.max_action"),
    }
)
REQUIRED_TECHNICAL_LITERALS = {
    "wallet.creation.passphrase.section": ("BIP-39",),
    "import.recovery.passphrase.section": ("BIP-39",),
    "import.recovery.suggestions.empty": ("BIP-39",),
    "import.recovery.word_list.menu": ("BIP-39",),
    "import.recovery.word_list.title": ("BIP-39",),
    "import.recovery.word_list.language.footer": ("BIP-39",),
    "import.recovery.word_list.binary.footer": (
        "BIP-39",
        "11",
        "00000000000",
        "11111111111",
    ),
}
CONSISTENT_TRANSLATION_PAIRS = (
    (
        "wallet.creation.passphrase.field",
        "import.recovery.passphrase.field",
    ),
    (
        "wallet.creation.passphrase.confirm_field",
        "import.recovery.passphrase.confirm_field",
    ),
    (
        "wallet.creation.passphrase.mismatch",
        "import.recovery.passphrase.mismatch",
    ),
    (
        "wallet.creation.passphrase.too_long",
        "import.recovery.passphrase.too_long",
    ),
    (
        "wallet.creation.passphrase.toolbar",
        "import.recovery.passphrase.toolbar",
    ),
    (
        "wallet.creation.passphrase.navigation",
        "import.recovery.passphrase.navigation",
    ),
    (
        "wallet.creation.passphrase.section",
        "import.recovery.passphrase.section",
    ),
)


def parse_strings(path: pathlib.Path) -> dict[str, str]:
    contents = path.read_text(encoding="utf-8")
    return {
        match.group("key"): match.group("value").strip()
        for match in ENTRY_PATTERN.finditer(contents)
    }


def duplicate_keys(path: pathlib.Path) -> list[str]:
    contents = path.read_text(encoding="utf-8")
    keys = [
        match.group("key")
        for match in ENTRY_PATTERN.finditer(contents)
    ]
    counts = Counter(keys)
    return sorted(key for key, count in counts.items() if count > 1)


def format_arguments(value: str) -> list[str]:
    return EN_AUDIT["format_argument_signature"](value)


def normalized_boundary_word(token: str) -> str:
    return token.strip(TOKEN_BOUNDARY_PUNCTUATION).casefold()


def is_parenthesized_ticker_duplicate(
    first_raw_token: str,
    second_raw_token: str,
) -> bool:
    """Allow canonical asset labels such as ``Gram (GRAM)``.

    The structural duplicate detector intentionally compares words without
    punctuation or case. That is useful for prose, but a parenthesized ticker
    is metadata rather than a repeated word. Keep the exception narrow: the
    second token must consist solely of the first token inside parentheses.
    """

    candidate = second_raw_token.strip()
    if not (candidate.startswith("(") and candidate.endswith(")")):
        return False
    return normalized_boundary_word(first_raw_token) == (
        normalized_boundary_word(candidate[1:-1])
    )


def structural_translation_defects(
    identifier: str,
    key: str,
    value: str,
) -> list[str]:
    if identifier == "en":
        return []

    defects: list[str] = []
    raw_tokens = value.split()
    normalized_tokens = [
        normalized_boundary_word(token) for token in raw_tokens
    ]
    for index in range(len(normalized_tokens) - 1):
        token = normalized_tokens[index]
        if (
            len(token) < 3
            or "%" in token
            or token != normalized_tokens[index + 1]
            or raw_tokens[index].endswith(SENTENCE_TERMINATORS)
            or is_parenthesized_ticker_duplicate(
                raw_tokens[index],
                raw_tokens[index + 1],
            )
            or (identifier, key, token)
            in ADJACENT_DUPLICATE_ALLOWLIST
        ):
            continue
        defects.append(f"repeats adjacent word {token!r}")

    for width in range(2, 7):
        for index in range(len(normalized_tokens) - (2 * width) + 1):
            first = normalized_tokens[index : index + width]
            second = normalized_tokens[
                index + width : index + (2 * width)
            ]
            if first != second or any("%" in token for token in first):
                continue
            phrase = " ".join(first)
            if (
                identifier,
                key,
                phrase,
            ) in ADJACENT_PHRASE_DUPLICATE_ALLOWLIST:
                continue
            repeated_raw = raw_tokens[index : index + (2 * width) - 1]
            if any(
                token.endswith(SENTENCE_TERMINATORS)
                for token in repeated_raw
            ):
                continue
            defects.append(
                "repeats adjacent phrase " + repr(phrase)
            )

    maximum_words = COMPACT_LABEL_MAX_WORDS.get(key)
    if maximum_words is not None and len(raw_tokens) > maximum_words:
        defects.append(
            f"has {len(raw_tokens)} words; compact label allows "
            f"at most {maximum_words}"
        )
    return defects


def swift_localization_references() -> dict[str, set[pathlib.Path]]:
    references: dict[str, set[pathlib.Path]] = {}
    for path in APP_DIRECTORY.rglob("*.swift"):
        contents = path.read_text(encoding="utf-8")
        for pattern in SWIFT_LOCALIZATION_PATTERNS:
            for match in pattern.finditer(contents):
                references.setdefault(match.group("key"), set()).add(path)

    send_paths = list((APP_DIRECTORY / "Send").glob("*.swift"))
    send_paths.append(APP_DIRECTORY / "SendWalletView.swift")
    for path in send_paths:
        contents = path.read_text(encoding="utf-8")
        for match in SEND_LITERAL_PATTERN.finditer(contents):
            key = match.group("key")
            if r"\(" in key:
                continue
            references.setdefault(key, set()).add(path)
    return references


def swift_english_fallback_keys() -> set[str]:
    fallback_keys: set[str] = set()
    direct_keys: set[str] = set()
    for path in APP_DIRECTORY.rglob("*.swift"):
        contents = path.read_text(encoding="utf-8")
        for match in SWIFT_ENGLISH_FALLBACK_PATTERN.finditer(contents):
            fallback_keys.add(match.group("key"))
        for pattern in SWIFT_DIRECT_LOCALIZATION_PATTERNS:
            for match in pattern.finditer(contents):
                direct_keys.add(match.group("key"))

    return fallback_keys - direct_keys


def hardcoded_swift_ui_literals() -> list[tuple[pathlib.Path, int, str]]:
    results: list[tuple[pathlib.Path, int, str]] = []
    localization_key = re.compile(r"^" + LOCALIZATION_KEY_PATTERN + r"$")
    for path in APP_DIRECTORY.rglob("*.swift"):
        contents = path.read_text(encoding="utf-8")
        for pattern in SWIFT_DIRECT_UI_LITERAL_PATTERNS:
            for match in pattern.finditer(contents):
                literal = match.group("literal")
                if localization_key.fullmatch(literal):
                    continue
                visible_literal = re.sub(r"\\\([^)]*\)", "", literal)
                if r"\(" in visible_literal:
                    continue
                if not re.search(r"[A-Za-z]{2,}", visible_literal):
                    continue
                line = contents.count("\n", 0, match.start()) + 1
                results.append((path, line, literal))
    return results


def translation_defect(
    identifier: str,
    key: str,
    english_value: str,
    localized_value: str,
) -> str | None:
    if identifier == "en":
        return None
    if CONTEXTUAL_TRANSLATION_ERRORS.get((identifier, key, english_value)) == localized_value:
        return "uses a known mistranslation for this screen context"
    if (
        key == "send.network_fee.custom.integer.placeholder"
        and english_value == "0.00"
        and localized_value != "0.00"
    ):
        return "does not match the ASCII decimal input format"
    if "_CODEX_KEY_" in localized_value:
        return "contains an internal localization marker"
    if re.match(
        r"^\s*(?:tl|translation)\s*>",
        localized_value,
        re.IGNORECASE,
    ):
        return "contains a malformed translation marker"
    if (
        key == "receive.details.network.badge.ton"
        and "formerly" in localized_value.casefold()
    ):
        return "still contains untranslated English copy"
    # These languages also use “bits”; accept only the compact count format.
    if (
        key == "wallet.creation.entropy.progress.value"
        and identifier in {"es", "fr", "nl", "pt-BR", "pt-PT"}
        and english_value == localized_value == "%1$d/%2$d bits"
    ):
        return None
    if (
        EN_AUDIT["is_invariant"](key, english_value)
        or EN_AUDIT["is_shared_translation"](identifier, key, english_value, localized_value)
        or not any(character.isalpha() for character in english_value)
        or (identifier, key)
        in SAME_AS_ENGLISH_TRANSLATION_ALLOWLIST
    ):
        return None
    if localized_value in ARCHIVED_ENGLISH_VALUES.get(key, set()):
        return "still uses an obsolete English source value"
    if localized_value.casefold() == english_value.casefold():
        return "still uses the English source value"
    if len(english_value) < 8:
        return None
    embedded_source = re.search(
        r"(?<!\w)" + re.escape(english_value) + r"(?!\w)",
        localized_value,
        re.IGNORECASE,
    )
    if embedded_source:
        return "contains the complete English source inside its translation"
    return None




MENU_LABEL_REFERENCES = {
    "device_migration.scan.instruction": (
        "settings.title", "settings.security.title", "device_migration.security.action",
    ),
    "device_migration.status.waiting.detail": ("device_migration.import.option.title",),
}


def menu_label_reference_defects(values: dict[str, str]) -> list[str]:
    errors: list[str] = []
    for instruction_key, label_keys in MENU_LABEL_REFERENCES.items():
        instruction = values.get(instruction_key, "").casefold()
        for label_key in label_keys:
            label = values.get(label_key, "").casefold()
            if label and label not in instruction:
                errors.append(f"{instruction_key} must reference the current translated {label_key}")
    return errors


def shortcut_catalog_defects(
    catalog: dict,
    supported: set[str],
    source_phrases: set[str],
) -> list[str]:
    errors: list[str] = []
    entries = catalog.get("strings", {})
    source_language = catalog.get("sourceLanguage")
    if source_language != "en":
        errors.append("AppShortcuts.xcstrings must use English as its source language")
    for phrase in sorted(source_phrases - entries.keys()):
        errors.append(f"AppShortcuts.xcstrings is missing source phrase {phrase!r}")
    for phrase, entry in entries.items():
        if phrase not in source_phrases:
            errors.append(f"AppShortcuts.xcstrings contains an unused phrase {phrase!r}")
        localizations = entry.get("localizations", {})
        expected_tokens = Counter(re.findall(r"\$\{[^}]+\}", phrase))
        for locale in sorted(supported):
            unit = localizations.get(locale, {}).get("stringUnit", {})
            value = unit.get("value", "")
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{locale} is missing shortcut translation {phrase!r}")
                continue
            if unit.get("state") != "translated":
                errors.append(f"{locale} shortcut {phrase!r} is not marked translated")
            if Counter(re.findall(r"\$\{[^}]+\}", value)) != expected_tokens:
                errors.append(f"{locale} shortcut {phrase!r} changes phrase placeholders")
            if locale != source_language and value.casefold() == phrase.casefold():
                errors.append(f"{locale} shortcut {phrase!r} still uses English")
        for locale in sorted(localizations.keys() - supported):
            errors.append(f"Shortcut {phrase!r} has an unsupported locale {locale}")
    return errors


def validate_shortcut_catalog(supported: set[str]) -> list[str]:
    source = (APP_DIRECTORY / "ApertureAppIntents.swift").read_text(encoding="utf-8")
    source_phrases = {
        phrase.replace(r"\(.applicationName)", "${applicationName}")
        for phrase in re.findall(r'"([^"\n]*\\\(\.applicationName\)[^"\n]*)"', source)
    }
    path = APP_DIRECTORY / "AppShortcuts.xcstrings"
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"Cannot read AppShortcuts.xcstrings: {error}"]
    return shortcut_catalog_defects(catalog, supported, source_phrases)


def fail(messages: list[str]) -> None:
    for message in messages:
        print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    with INFO_PLIST.open("rb") as stream:
        info = plistlib.load(stream)
    supported = set(info.get("CFBundleLocalizations", []))
    localized_directories = {
        path.name.removesuffix(".lproj")
        for path in APP_DIRECTORY.glob("*.lproj")
        if (path / "InfoPlist.strings").is_file()
    }

    errors: list[str] = validate_shortcut_catalog(supported)
    missing_directories = sorted(supported - localized_directories)
    unexpected_directories = sorted(localized_directories - supported)
    if missing_directories:
        errors.append(
            "missing InfoPlist.strings localizations: "
            + ", ".join(missing_directories)
        )
    if unexpected_directories:
        errors.append(
            "InfoPlist.strings locales are absent from CFBundleLocalizations: "
            + ", ".join(unexpected_directories)
        )

    english_path = APP_DIRECTORY / "en.lproj" / "InfoPlist.strings"
    english = parse_strings(english_path)
    for key in REQUIRED_PERMISSION_KEYS:
        if not english.get(key):
            errors.append(f"English localization is missing {key}")

    for identifier in sorted(supported):
        path = APP_DIRECTORY / f"{identifier}.lproj" / "InfoPlist.strings"
        if not path.is_file():
            continue
        values = parse_strings(path)
        for key in REQUIRED_PERMISSION_KEYS:
            value = values.get(key, "")
            if not value:
                errors.append(f"{identifier} is missing a nonempty {key}")
            elif identifier != "en" and value == english.get(key):
                errors.append(
                    f"{identifier} still uses the English value for {key}"
                )

    english_localizable_path = (
        APP_DIRECTORY / "en.lproj" / LOCALIZABLE_FILENAME
    )
    english_localizable = parse_strings(english_localizable_path)
    english_keys = set(english_localizable)
    if duplicates := duplicate_keys(english_localizable_path):
        errors.append(
            "en has duplicate Localizable.strings keys: "
            + ", ".join(duplicates)
        )
    localization_references = swift_localization_references()
    english_fallback_keys = swift_english_fallback_keys()
    missing_english_keys = sorted(
        set(localization_references) - english_keys
    )
    for key in missing_english_keys:
        relative_paths = sorted(
            str(path.relative_to(ROOT))
            for path in localization_references[key]
        )
        errors.append(
            f"Swift references missing English localization key {key}: "
            + ", ".join(relative_paths)
        )
    for path, line, literal in hardcoded_swift_ui_literals():
        errors.append(
            "Swift contains a hardcoded user-facing UI literal "
            f"{literal!r}: {path.relative_to(ROOT)}:{line}"
        )

    for identifier in sorted(supported):
        path = (
            APP_DIRECTORY
            / f"{identifier}.lproj"
            / LOCALIZABLE_FILENAME
        )
        if not path.is_file():
            errors.append(
                f"{identifier} is missing {LOCALIZABLE_FILENAME}"
            )
            continue

        values = parse_strings(path)
        errors.extend(f"{identifier} {error}" for error in menu_label_reference_defects(values))
        keys = set(values)
        if duplicates := duplicate_keys(path):
            errors.append(
                f"{identifier} has duplicate Localizable.strings keys: "
                + ", ".join(duplicates)
            )

        unexpected_keys = sorted(keys - english_keys)
        if unexpected_keys:
            errors.append(
                f"{identifier} has Localizable.strings keys absent from en: "
                + ", ".join(unexpected_keys)
            )
        missing_keys = english_keys - keys - english_fallback_keys
        if missing_keys:
            errors.append(
                f"{identifier} is missing Localizable.strings keys: "
                + ", ".join(sorted(missing_keys))
            )

        for key in sorted(english_keys & keys):
            value = values[key]
            if not value:
                errors.append(f"{identifier} {key} has an empty value")
            localized_digits = sorted(
                {
                    character
                    for character in value
                    if character.isdecimal()
                    and not ("0" <= character <= "9")
                }
            )
            if localized_digits:
                errors.append(
                    f"{identifier} {key} contains non-ASCII decimal "
                    f"digits: {localized_digits}"
                )
            expected_exact_value = REQUIRED_EXACT_LOCALIZED_VALUES.get(
                (identifier, key)
            )
            if (
                expected_exact_value is not None
                and value != expected_exact_value
            ):
                errors.append(
                    f"{identifier} {key} must be "
                    f"{expected_exact_value!r}, got {value!r}"
                )
            for literal in REQUIRED_TECHNICAL_LITERALS.get(key, ()):
                if literal not in value:
                    errors.append(
                        f"{identifier} {key} is missing required "
                        f"literal {literal!r}"
                    )
            for defect in structural_translation_defects(
                identifier,
                key,
                value,
            ):
                errors.append(f"{identifier} {key} {defect}")
            expected_arguments = format_arguments(
                english_localizable[key]
            )
            actual_arguments = format_arguments(value)
            if actual_arguments != expected_arguments:
                errors.append(
                    f"{identifier} changes format arguments for {key}: "
                    f"expected {expected_arguments}, got {actual_arguments}"
                )
            if defect := translation_defect(
                identifier,
                key,
                english_localizable[key],
                value,
            ):
                errors.append(f"{identifier} {key} {defect}")

        for first_key, second_key in CONSISTENT_TRANSLATION_PAIRS:
            first_value = values.get(first_key)
            second_value = values.get(second_key)
            if (
                first_value is not None
                and second_value is not None
                and first_value != second_value
            ):
                errors.append(
                    f"{identifier} must translate {first_key} and "
                    f"{second_key} consistently"
                )

    if errors:
        fail(errors)

    print(
        "Validated permission descriptions, Siri shortcut translations, "
        f"{len(localization_references)} Swift localization references, "
        "localized key parity with explicit English fallbacks, "
        "English source keys, translated-key "
        "integrity, structural quality, ASCII digits, and format "
        f"arguments for {len(supported)} locales."
    )


if __name__ == "__main__":
    main()

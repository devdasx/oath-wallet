#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EN localization key cache + audit.

Always remembers previous English key→value state so other languages can be
fixed when EN is added, removed, or changed.

Usage (from repo root):
  python3 Oath/l10n/audit_en_keys.py

Cache files (under Oath/l10n/):
  en_keys_snapshot.json       Current EN baseline (key→value)
  en_keys_snapshot.prev.json  Last *different* EN snapshot (not overwritten on no-op)
  en_keys_archive/            Timestamped full EN dumps whenever EN changes
  en_keys_memory.json         Permanent memory of every add/remove/change ever seen
  en_keys_last_diff.json      Machine-readable last compare + locale gaps
  en_keys_history.jsonl       Append-only audit log
"""
from __future__ import annotations

import json
import re
import shutil
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # Oath/
EN_LOC = ROOT / "en.lproj" / "Localizable.strings"
EN_IP = ROOT / "en.lproj" / "InfoPlist.strings"
CACHE_DIR = Path(__file__).resolve().parent
SNAPSHOT = CACHE_DIR / "en_keys_snapshot.json"
SNAPSHOT_PREV = CACHE_DIR / "en_keys_snapshot.prev.json"
ARCHIVE_DIR = CACHE_DIR / "en_keys_archive"
MEMORY = CACHE_DIR / "en_keys_memory.json"
LAST_DIFF = CACHE_DIR / "en_keys_last_diff.json"
HISTORY = CACHE_DIR / "en_keys_history.jsonl"

PARSE_RE = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
PH_RE = re.compile(r"%(?:\d+\$)?[@dDilLfFsSuUxX]|%\{[^}]+\}|\{[a-zA-Z_]+\}")

# Explicit source values, not key prefixes: adding descriptive copy to a brand
# or protocol label must re-enable translation checks.
INVARIANT_KEY_VALUES = {
    "markets.sentiment.source": "CoinMarketCap",  # Required provider brand attribution.
    "asset.aptos.name": "Aptos",
    "asset.gram.name": "Gram",
    "asset.near.name": "Near Protocol",
    "asset.near.token.ref.name": "Ref Finance (REF)",
    "asset.near.token.usdt.name": "Tether USD (USDT)",
    "asset.near.token.wnear.name": "Wrapped NEAR (wNEAR)",
    "asset.stellar_lumen.name": "Stellar",
    "asset.sui.name": "Sui",
    "asset.sui.token.cetus.name": "Cetus Protocol (CETUS)",
    "asset.sui.token.deep.name": "DeepBook (DEEP)",
    "asset.sui.token.mmt.name": "Momentum (MMT)",
    "asset.sui.token.navx.name": "NAVX Token (NAVX)",
    "asset.sui.token.sca.name": "Scallop (SCA)",
    "asset.sui.token.usdc.name": "USD Coin (USDC)",
    "asset.sui.token.usdt.name": "Tether USD (USDT)",
    "asset.xrp.name": "XRP",
    "asset.xrp.token.rlusd.name": "Ripple USD (RLUSD)",
    "brand.name": "Oath Wallet",
    "brand.name.uppercase": "OATH WALLET",
    "onboarding.era.brand": "Oath",
    "network.aptos.name": "Aptos",
    "network.arbitrum": "Arbitrum",
    "network.arc": "Arc",
    "asset.family.bstocks": "bStocks",
    "network.avalanche": "Avalanche C-Chain",
    "network.base": "Base",
    "network.bitcoin.name": "Bitcoin",
    "network.bitcoin_cash.name": "Bitcoin Cash",
    "network.bnb_smart_chain": "BNB Smart Chain",
    "network.dogecoin.name": "Dogecoin",
    "network.ethereum": "Ethereum",
    "network.gnosis": "Gnosis",
    "network.linea": "Linea",
    "network.litecoin.name": "Litecoin",
    "network.near.name": "NEAR Protocol",
    "network.optimism": "Optimism",
    "network.polygon": "Polygon",
    "network.scroll": "Scroll",
    "network.solana.name": "Solana",
    "network.stellar.name": "Stellar",
    "network.taiko": "Taiko",
    "network.telos": "Telos",
    "network.ton.name": "TON",
    "network.tron.name": "TRON",
    "network.x_layer": "X Layer",
    "network.xrp.name": "XRP Ledger",
    "receive.amount.placeholder": "0.00",
    "receive.bitcoin.address_type.brdLegacy": "BRD · Legacy",
    "receive.bitcoin.address_type.brdSegwit": "BRD · Native SegWit",
    "receive.bitcoin.address_type.bip44": "BIP44 · Legacy",
    "receive.bitcoin.address_type.bip49": "BIP49 · Nested SegWit",
    "receive.bitcoin.address_type.bip84": "BIP84 · Native SegWit",
    "receive.bitcoin.address_type.bip86": "BIP86 · Taproot",
    "receive.bitcoin.address_type.rawtr": "Taproot",
    "send.amount.asset_placeholder": "%1$@ (%2$@)",
    "send.bitcoin.op_return.title": "OP_RETURN",
    "send.network_fee.custom.integer.placeholder": "0.00",
    "settings.tools.evm_access.section": "EVM",
    "wallet.asset.chainlink.name": "Chainlink (LINK)",
    "wallet.asset.ethereum.name": "Ether (ETH)",
    "wallet.asset.usdc.name": "USD Coin (USDC)",
    "wallet.format.asset_amount": "%1$@ %2$@",
    "wallet.home.card.wordmark": "Oath Wallet",
    "wallet.home.value.hidden.visual": "••••"
}
KEEP_KEYS = set(INVARIANT_KEY_VALUES)
KEEP_VALS = {
    "0",
    "1",
    "1.0",
    "0.00",
    "••••••",
    "OK",
    "OATH",
    "Oath",
    "%1$@ %2$@",
    "%@, %@",
    "USD",
    "Ethereum",
    "Chainlink",
    "USD Coin",
    "%@ Gwei",
    "1 USD = %1$@ %2$@",
    "Face ID",
    "Touch ID",
    "Optic ID",
    "Bitcoin",
    "Bitcoin Cash",
    "Litecoin",
    "Dogecoin",
    "TRON",
    "Solana",
    "TON",
    "0x…",
    "Phantom",
    "Trust Wallet",
    "Solana (Phantom)",
    "Solana (Trust Wallet)",
    "%1$@ Gwei",
    "%1$@ sat/vB",
    "%1$@ micro-lamports/CU",
    "%1$@ sun/energy • %2$@ sun/bandwidth",
    "0.00000000",
}


# Valid native spellings/technical loanwords, scoped to the exact source value.
# A later wording change must not inherit these exceptions.
SHARED_LANGUAGE_VALUES = {
    ("transaction_export.wallet", "Wallet"): {"de"},
    ("send.network_fee.preset.standard.title", "Standard"): {
        "da", "de", "fr", "it", "ms", "nb", "ro", "sv",
    },
    ("markets.sentiment.neutral", "Neutral"): {"da", "de", "es", "fil", "ms", "sv"},
    # Filipino uses the computing loanword "Network" for a blockchain network.
    ("wallet.transaction.details.network", "Network"): {"fil"},
    ("bitcoin.settings.silent.transaction.section", "Transaction"): {"fr"},
    ("import.bip38.password", "Password"): {"fil", "it"},
    ("settings.about.version.value", "Version 2.40.08"): {"da", "de", "fr", "sv"},
    ("settings.about.build.value", "Build 21"): {"da", "de", "fil", "id", "it", "nl"},
    ("wallet.assets.loading.symbol", "TOKEN"): {
        "cs", "da", "de", "es", "fi", "fil", "ha", "hr", "hu", "id", "it",
        "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "sk", "sv", "tr",
        "uz", "vi", "yo",
    },
    ("security.authentication.passcode.duration.minute.one", "%d min"): {
        "cs", "fr", "hr", "nb", "pl", "ro", "sk", "sl",
    },
    ("security.authentication.passcode.duration.minute.other", "%d min"): {
        "cs", "fr", "hr", "nb", "pl", "ro", "sk", "sl",
    },
    ("security.authentication.passcode.duration.second.one", "%d sec"): {"ro"},
    ("security.authentication.passcode.duration.second.other", "%d sec"): {"ro"},
}


def is_shared_translation(locale: str, key: str, english: str, localized: str) -> bool:
    return localized == english and locale in SHARED_LANGUAGE_VALUES.get((key, english), set())


def is_invariant(key: str, value: str) -> bool:
    return INVARIANT_KEY_VALUES.get(key) == value or value in KEEP_VALS


def format_argument_signature(value: str) -> list[str]:
    """Compare argument identities/types, allowing translators to reorder them."""
    tokens = re.findall(r"%%|%(?:[1-9][0-9]*\$)?(?:lld|llu|ld|lu|[@dDiLfFsSuUxX])|%\{[^}]+\}|\{[a-zA-Z_]+\}", value)
    result = []
    sequential = 0
    modes = set()
    for token in tokens:
        if token == '%%':
            continue
        match = re.fullmatch(r"%(?:([1-9][0-9]*)\$)?(.+)", token)
        if match and not token.startswith('%{'):
            position, kind = match.groups()
            modes.add('positional' if position else 'sequential')
            if not position:
                sequential += 1
            result.append(f"%{position or sequential}${kind}")
        else:
            result.append(token)
    if len(modes) > 1:
        result.append('INVALID_MIXED_POSITIONAL_ARGUMENTS')
    return sorted(result)


def parse(path: Path) -> dict[str, str]:
    d: dict[str, str] = {}
    if not path.exists():
        return d
    for line in path.read_text(encoding="utf-8").splitlines():
        m = PARSE_RE.match(line.strip())
        if m:
            d[m.group(1)] = m.group(2)
    return d


def load_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def load_snapshot() -> dict | None:
    return load_json(SNAPSHOT)


def write_json(path: Path, payload: dict) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def make_snapshot_payload(
    localizable: dict[str, str], infoplist: dict[str, str], saved_at: str | None = None
) -> dict:
    return {
        "saved_at": saved_at or datetime.now(timezone.utc).isoformat(),
        "localizable_count": len(localizable),
        "infoplist_count": len(infoplist),
        "localizable": localizable,
        "infoplist": infoplist,
    }


def save_snapshot(localizable: dict[str, str], infoplist: dict[str, str]) -> dict:
    payload = make_snapshot_payload(localizable, infoplist)
    write_json(SNAPSHOT, payload)
    return payload


def has_en_changes(loc_diff: dict, ip_diff: dict) -> bool:
    return bool(
        loc_diff["added"]
        or loc_diff["removed"]
        or loc_diff["changed"]
        or ip_diff["added"]
        or ip_diff["removed"]
        or ip_diff["changed"]
    )


def compare(old: dict[str, str] | None, new: dict[str, str], label: str) -> dict:
    old = old or {}
    old_keys, new_keys = set(old), set(new)
    added = sorted(new_keys - old_keys)
    removed = sorted(old_keys - new_keys)
    changed = sorted(k for k in (old_keys & new_keys) if old[k] != new[k])
    return {
        "label": label,
        "added": [(k, new[k]) for k in added],
        "removed": [(k, old[k]) for k in removed],
        "changed": [(k, old[k], new[k]) for k in changed],
    }


def print_diff(diff: dict, limit: int = 40) -> None:
    print(f"=== {diff['label']} (vs cached EN) ===")
    print(f"  Added:   {len(diff['added'])}")
    print(f"  Removed: {len(diff['removed'])}")
    print(f"  Changed: {len(diff['changed'])}")
    for k, v in diff["added"][:limit]:
        print(f"  + {k} = {v!r}")
    if len(diff["added"]) > limit:
        print(f"  ... +{len(diff['added']) - limit} more added")
    for k, v in diff["removed"][:limit]:
        print(f"  - {k} = {v!r}")
    if len(diff["removed"]) > limit:
        print(f"  ... +{len(diff['removed']) - limit} more removed")
    for k, old, new in diff["changed"][:limit]:
        print(f"  ~ {k}")
        print(f"      old: {old!r}")
        print(f"      new: {new!r}")
    if len(diff["changed"]) > limit:
        print(f"  ... +{len(diff['changed']) - limit} more changed")
    print()


def serialize_diff(diff: dict) -> dict:
    return {
        "added": [{"key": k, "value": v} for k, v in diff["added"]],
        "removed": [{"key": k, "value": v} for k, v in diff["removed"]],
        "changed": [
            {"key": k, "old": old, "new": new} for k, old, new in diff["changed"]
        ],
    }


def archive_snapshot(snapshot: dict, reason: str) -> Path:
    """Write a full timestamped copy of an EN snapshot that is being superseded."""
    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    # Keep filesystem-safe stamp uniqueness if many archives in one second
    path = ARCHIVE_DIR / f"en_keys_{stamp}_{reason}.json"
    n = 1
    while path.exists():
        path = ARCHIVE_DIR / f"en_keys_{stamp}_{reason}_{n}.json"
        n += 1
    write_json(path, snapshot)
    return path


def load_memory() -> dict:
    mem = load_json(MEMORY)
    if not mem:
        return {
            "updated_at": None,
            "localizable": {},  # key -> {current, first_seen, last_changed, history: [...]}
            "infoplist": {},
            "removed_localizable": {},  # key -> {last_value, removed_at, history}
            "removed_infoplist": {},
        }
    # Backfill structure if older/partial
    for k in (
        "localizable",
        "infoplist",
        "removed_localizable",
        "removed_infoplist",
    ):
        mem.setdefault(k, {})
    return mem


def _key_entry(
    value: str, at: str, event: str, old: str | None = None
) -> dict:
    entry: dict = {"at": at, "event": event, "value": value}
    if old is not None:
        entry["old"] = old
    return entry


def update_memory(
    mem: dict,
    domain: str,
    removed_domain: str,
    old_map: dict[str, str] | None,
    new_map: dict[str, str],
    at: str,
    loc_diff: dict,
) -> None:
    """Accumulate permanent add/change/remove memory for one domain (localizable/infoplist)."""
    old_map = old_map or {}
    keys_domain = mem[domain]
    removed_domain_map = mem[removed_domain]

    for k, v in loc_diff["added"]:
        # resurrect if previously removed
        removed_domain_map.pop(k, None)
        if k not in keys_domain:
            keys_domain[k] = {
                "current": v,
                "first_seen": at,
                "last_changed": at,
                "history": [_key_entry(v, at, "added")],
            }
        else:
            entry = keys_domain[k]
            prev = entry.get("current")
            entry["current"] = v
            entry["last_changed"] = at
            entry.setdefault("history", []).append(
                _key_entry(v, at, "re_added", old=prev)
            )

    for k, old_v in loc_diff["removed"]:
        entry = keys_domain.pop(k, None)
        history = []
        if entry:
            history = list(entry.get("history") or [])
            history.append(_key_entry(old_v, at, "removed", old=entry.get("current")))
        else:
            history = [_key_entry(old_v, at, "removed")]
        removed_domain_map[k] = {
            "last_value": old_v,
            "removed_at": at,
            "history": history,
        }

    for k, old_v, new_v in loc_diff["changed"]:
        if k not in keys_domain:
            keys_domain[k] = {
                "current": new_v,
                "first_seen": at,
                "last_changed": at,
                "history": [
                    _key_entry(old_v, at, "known_old"),
                    _key_entry(new_v, at, "changed", old=old_v),
                ],
            }
        else:
            entry = keys_domain[k]
            entry["current"] = new_v
            entry["last_changed"] = at
            entry.setdefault("history", []).append(
                _key_entry(new_v, at, "changed", old=old_v)
            )

    # Ensure every currently live key is present in memory (baseline fill)
    for k, v in new_map.items():
        if k not in keys_domain:
            keys_domain[k] = {
                "current": v,
                "first_seen": at,
                "last_changed": at,
                "history": [_key_entry(v, at, "baseline")],
            }
        else:
            # Keep current in sync even if compare found no change
            keys_domain[k]["current"] = v


def write_last_diff(
    loc_diff: dict,
    ip_diff: dict,
    missing: dict[str, list[str]],
    ph_bad: list,
    multi: list,
    stale_old_english: list,
    cur_loc: dict[str, str],
    cur_ip: dict[str, str],
    prev_saved_at: str | None,
    en_changed: bool,
    archive_path: str | None,
) -> None:
    payload = {
        "at": datetime.now(timezone.utc).isoformat(),
        "compared_against_snapshot_at": prev_saved_at,
        "en_changed": en_changed,
        "archived_previous_snapshot": archive_path,
        "current_counts": {
            "localizable": len(cur_loc),
            "infoplist": len(cur_ip),
        },
        "localizable": serialize_diff(loc_diff),
        "infoplist": serialize_diff(ip_diff),
        "locale_parity": {
            "missing_keys": {
                k: {"en": cur_loc[k], "locales_missing": locs}
                for k, locs in sorted(missing.items())
            },
            "placeholder_mismatches": [
                {"locale": loc, "key": k, "en": ev, "locale_value": lv}
                for loc, k, ev, lv in ph_bad
            ],
            "same_as_en_multiword_ge_10": {
                k: {"en": cur_loc[k], "locales": locs} for k, locs in multi
            },
            "stale_old_english_values": [
                {
                    "locale": locale,
                    "key": key,
                    "old_en": old_value,
                    "current_en": cur_loc[key],
                }
                for locale, key, old_value in stale_old_english
            ],
        },
        "action_needed": bool(
            loc_diff["added"]
            or loc_diff["removed"]
            or loc_diff["changed"]
            or ip_diff["added"]
            or ip_diff["removed"]
            or ip_diff["changed"]
            or missing
            or ph_bad
            or multi
            or stale_old_english
        ),
    }
    write_json(LAST_DIFF, payload)


def append_history(entry: dict) -> None:
    with HISTORY.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def historical_old_values(
    memory: dict,
    domain: str,
) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for key, entry in memory.get(domain, {}).items():
        current = entry.get("current")
        values: set[str] = set()
        for event in entry.get("history", []):
            for field in ("old", "value"):
                value = event.get(field)
                if value and value != current:
                    values.add(value)
        if values:
            result[key] = values
    return result


def main() -> int:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)

    cur_loc = parse(EN_LOC)
    cur_ip = parse(EN_IP)
    prev = load_snapshot()
    prev_saved_at = prev.get("saved_at") if prev else None
    now = datetime.now(timezone.utc).isoformat()

    print(f"Current EN Localizable: {len(cur_loc)} keys")
    print(f"Current EN InfoPlist:   {len(cur_ip)} keys")
    print(f"Snapshot file:      {SNAPSHOT}")
    print(f"Previous snapshot:  {SNAPSHOT_PREV}")
    print(f"Permanent memory:   {MEMORY}")
    print(f"Archive directory:  {ARCHIVE_DIR}")
    print(f"Last diff file:     {LAST_DIFF}")
    print()

    archive_path: str | None = None
    en_changed = False
    mem = load_memory()

    if prev is None:
        save_snapshot(cur_loc, cur_ip)
        if SNAPSHOT.exists():
            shutil.copy2(SNAPSHOT, SNAPSHOT_PREV)
        update_memory(mem, "localizable", "removed_localizable", {}, cur_loc, now, {
            "added": list(cur_loc.items()),
            "removed": [],
            "changed": [],
        })
        update_memory(mem, "infoplist", "removed_infoplist", {}, cur_ip, now, {
            "added": list(cur_ip.items()),
            "removed": [],
            "changed": [],
        })
        mem["updated_at"] = now
        write_json(MEMORY, mem)
        append_history(
            {
                "at": now,
                "event": "baseline",
                "localizable_count": len(cur_loc),
                "infoplist_count": len(cur_ip),
            }
        )
        print("No previous snapshot — baseline created from current EN.")
        print("Old EN will be retained on every future change (prev + archive + memory).")
        loc_diff = compare({}, cur_loc, "Localizable")
        ip_diff = compare({}, cur_ip, "InfoPlist")
    else:
        print(f"Cached snapshot from: {prev.get('saved_at')}")
        print(
            f"  was Localizable={prev.get('localizable_count')} "
            f"InfoPlist={prev.get('infoplist_count')}"
        )
        print()
        loc_diff = compare(prev.get("localizable", {}), cur_loc, "Localizable")
        ip_diff = compare(prev.get("infoplist", {}), cur_ip, "InfoPlist")
        print_diff(loc_diff)
        print_diff(ip_diff)

        en_changed = has_en_changes(loc_diff, ip_diff)

        if en_changed:
            # 1) Archive full previous EN so it is never lost
            archived = archive_snapshot(prev, "before_change")
            archive_path = str(archived)
            print(f"Archived previous EN snapshot: {archived.name}")

            # 2) Keep prev as the last *different* EN (overwrite only when changed)
            write_json(SNAPSHOT_PREV, prev)
            print(f"Previous EN retained at: {SNAPSHOT_PREV.name}")

            # 3) Permanent memory of every add / remove / change with old values
            update_memory(
                mem,
                "localizable",
                "removed_localizable",
                prev.get("localizable", {}),
                cur_loc,
                now,
                loc_diff,
            )
            update_memory(
                mem,
                "infoplist",
                "removed_infoplist",
                prev.get("infoplist", {}),
                cur_ip,
                now,
                ip_diff,
            )
            mem["updated_at"] = now
            write_json(MEMORY, mem)
            print(f"Permanent EN memory updated: {MEMORY.name}")

            # 4) Refresh current snapshot
            save_snapshot(cur_loc, cur_ip)
            print("Current snapshot refreshed to live EN.")

            append_history(
                {
                    "at": now,
                    "event": "compare_changed",
                    "compared_against": prev_saved_at,
                    "archived": archive_path,
                    "localizable": serialize_diff(loc_diff),
                    "infoplist": serialize_diff(ip_diff),
                    "counts": {
                        "localizable": len(cur_loc),
                        "infoplist": len(cur_ip),
                    },
                }
            )
        else:
            # No EN change: do NOT overwrite prev or archive.
            # Still refresh current snapshot timestamps/counts if needed, keep prev intact.
            update_memory(
                mem,
                "localizable",
                "removed_localizable",
                prev.get("localizable", {}),
                cur_loc,
                now,
                loc_diff,
            )
            update_memory(
                mem,
                "infoplist",
                "removed_infoplist",
                prev.get("infoplist", {}),
                cur_ip,
                now,
                ip_diff,
            )
            mem["updated_at"] = now
            write_json(MEMORY, mem)
            save_snapshot(cur_loc, cur_ip)
            # Ensure prev exists (first upgrade path)
            if not SNAPSHOT_PREV.exists() and SNAPSHOT.exists():
                shutil.copy2(SNAPSHOT, SNAPSHOT_PREV)
            print("No EN key/value changes — previous snapshot kept intact.")
            print(f"Previous EN still at: {SNAPSHOT_PREV}")
            append_history(
                {
                    "at": now,
                    "event": "compare_unchanged",
                    "compared_against": prev_saved_at,
                    "counts": {
                        "localizable": len(cur_loc),
                        "infoplist": len(cur_ip),
                    },
                }
            )

    # Locale parity
    locales = sorted(
        p.name.replace(".lproj", "")
        for p in ROOT.iterdir()
        if p.is_dir() and p.name.endswith(".lproj") and p.name != "en.lproj"
    )
    missing: dict[str, list[str]] = defaultdict(list)
    ph_bad: list[tuple[str, str, str, str]] = []
    same: dict[str, list[str]] = defaultdict(list)
    stale_old_english: list[tuple[str, str, str]] = []
    old_english_values = historical_old_values(mem, "localizable")
    for loc in locales:
        d = parse(ROOT / f"{loc}.lproj" / "Localizable.strings")
        for k in set(cur_loc) - set(d):
            missing[k].append(loc)
        for k, ev in cur_loc.items():
            if k not in d:
                continue
            if format_argument_signature(ev) != format_argument_signature(d[k]):
                ph_bad.append((loc, k, ev, d[k]))
            invariant = is_invariant(k, ev) or is_shared_translation(loc, k, ev, d[k])
            if (
                not invariant
                and d[k] in old_english_values.get(k, set())
            ):
                stale_old_english.append((loc, k, d[k]))
            if invariant:
                continue
            if d.get(k) == ev and (" " in ev or len(ev) > 15):
                same[k].append(loc)

    multi = [(k, locs) for k, locs in same.items() if len(locs) >= 10]
    multi_sorted = sorted(multi, key=lambda x: -len(x[1]))

    print()
    print("=== Locale parity ===")
    print(f"  Locales: {len(locales)}")
    print(f"  Keys missing from some locales: {len(missing)}")
    for k, locs in sorted(missing.items())[:40]:
        print(f"  [{len(locs):2d}] {k} = {cur_loc[k]!r}")
    if len(missing) > 40:
        print(f"  ... +{len(missing) - 40} more missing keys")
    print(f"  Placeholder mismatches: {len(ph_bad)}")
    print(f"  Exact archived-English values: {len(stale_old_english)}")
    for loc, key, old_value in stale_old_english[:40]:
        print(f"  [{loc}] {key} still equals old EN {old_value!r}")
    if len(stale_old_english) > 40:
        print(
            "  ... +"
            f"{len(stale_old_english) - 40} more archived-English values"
        )
    print(f"  Multi-word same-as-EN in >=10 locales: {len(multi_sorted)}")
    for k, locs in multi_sorted[:30]:
        print(f"  [{len(locs)}] {k} = {cur_loc[k]!r}")

    # Surface permanent memory of recent EN changes for translators
    if en_changed:
        print()
        print("=== Cached EN changes (use these old values for retranslation) ===")
        for k, old, new in loc_diff["changed"][:50]:
            print(f"  ~ {k}")
            print(f"      old EN: {old!r}")
            print(f"      new EN: {new!r}")
        for k, v in loc_diff["removed"][:30]:
            print(f"  - {k} (last EN: {v!r})")
        for k, v in loc_diff["added"][:30]:
            print(f"  + {k} = {v!r}")

    write_last_diff(
        loc_diff,
        ip_diff,
        dict(missing),
        ph_bad,
        multi_sorted,
        stale_old_english,
        cur_loc,
        cur_ip,
        prev_saved_at,
        en_changed,
        archive_path,
    )
    print(f"\nLast diff written: {LAST_DIFF}")

    needs_work = (
        bool(loc_diff["added"])
        or bool(loc_diff["removed"])
        or bool(loc_diff["changed"])
        or bool(ip_diff["added"])
        or bool(ip_diff["removed"])
        or bool(ip_diff["changed"])
        or bool(missing)
        or bool(ph_bad)
        or bool(multi_sorted)
        or bool(stale_old_english)
    )
    print()
    if needs_work:
        print("ACTION NEEDED: translate new/changed EN keys into locales (or fix stubs).")
        print("Use en_keys_last_diff.json for the exact added/removed/changed set.")
        print("Old EN values: en_keys_snapshot.prev.json, en_keys_memory.json, en_keys_archive/.")
        return 1
    print("No EN changes requiring locale work; locales at full parity.")
    print("Old EN cache preserved (prev + memory + archive).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

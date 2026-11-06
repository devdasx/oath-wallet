#!/usr/bin/env python3
"""Explicit refresh of public artwork metadata, matched to released identities.
Builds consume the accepted snapshot without network access. Provider failures
retain previously accepted matches; no symbol-based guesses or paid API calls.
"""
import argparse, base64, binascii, gzip, hashlib, json, re, subprocess, time
import urllib.request, urllib.parse
from pathlib import Path
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'Website/content/tokens/artwork.json.gz'
HOSTS = {'assets.coingecko.com', 'coin-images.coingecko.com', 'raw.githubusercontent.com', 'static.debank.com'}

def logo_url(value):
    if not isinstance(value, str) or len(value) > 2048: return None
    try:
        u = urllib.parse.urlsplit(value)
        if u.scheme not in ('http', 'https') or u.hostname not in HOSTS or u.username or u.password or u.port: return None
        return urllib.parse.urlunsplit(('https', u.netloc, u.path, u.query, ''))
    except ValueError: return None

def canonical(network, reference):
    if not isinstance(reference, str) or len(reference) > 4096: return None
    if network == 'ton':
        if re.fullmatch(r'-?\d+:[a-fA-F0-9]{64}', reference): return reference.lower()
        try:
            raw = base64.urlsafe_b64decode(reference + '=' * (-len(reference) % 4))
            if len(raw) != 36 or (raw[0] & 0x7f) not in (0x11, 0x51) or binascii.crc_hqx(raw[:34], 0).to_bytes(2, 'big') != raw[34:]: return None
            return str(int.from_bytes(raw[1:2], 'big', signed=True)) + ':' + raw[2:34].hex()
        except (ValueError, binascii.Error): return None
    if network in ('aptos', 'sui'):
        parts = reference.split('::')
        if not re.fullmatch(r'0x[0-9a-fA-F]{1,64}', parts[0]): return None
        return '::'.join(['0x' + parts[0][2:].lower().zfill(64)] + parts[1:])
    if network == 'polkadot' and reference.isdigit(): return 'assets:' + reference
    if network == 'stellar': return reference.replace(':', '-')
    if network == 'xrpl' and '.' in reference:
        code, issuer = reference.rsplit('.', 1)
        if re.fullmatch(r'[a-fA-F0-9]{40}', code): code = code.upper()
        elif 3 < len(code.encode()) <= 20: code = code.encode().hex().upper().ljust(40, '0')
        return code + '.' + issuer
    if re.fullmatch(r'0x[a-fA-F0-9]{40}', reference): return reference.lower()
    return reference

def refresh(args):
    source = json.loads(gzip.decompress((ROOT / 'Website/content/tokens/source.json.gz').read_bytes()))
    def released(path):
        return subprocess.check_output(['git', 'show', source['revision'] + ':' + path], cwd=ROOT)
    swift = released('Packages/OathAnkr/Sources/OathAnkr/TokenDiscoveryCatalog.swift').decode()
    section = swift.split('public static let platforms:')[1].split('static let networksByPlatform')[0]
    platforms = dict(re.findall(r'"([a-z0-9-]+)": "([a-z0-9-]+)"', section))
    networks = {n['id']: n for n in json.loads((ROOT / 'Website/content/networks.json').read_text())['networks']}
    entries = {(e['network'], canonical(e['network'], e['reference'])): e for e in source['entries']}
    accepted = json.loads(gzip.decompress(DEST.read_bytes())) if DEST.exists() else {}
    current = {e['network'] + ':' + e['reference'] for e in source['entries']}
    images = {key: value for key, value in accepted.get('images', {}).items() if key in current and logo_url(value)}
    for e in source['entries']:
        if url := logo_url(e.get('logo')): images[e['network'] + ':' + e['reference']] = url
    # Same enrichment rule as the app: asset ID AND its exact network reference.
    details = released('Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoveryDetails.json')
    for detail in json.loads(details):
        url = logo_url(detail.get('image', {}).get('small'))
        if not url: continue
        for network, platform in platforms.items():
            reference = detail.get('detail_platforms', {}).get(platform, {}).get('contract_address')
            e = entries.get((network, canonical(network, reference)))
            if e and e['coinID'] == detail['id']: images[network + ':' + e['reference']] = url
    reports = []
    for network in sorted({e['network'] for e in source['entries']}):
        url = ('https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/167000.json' if network == 'taiko'
               else 'https://tokens.coingecko.com/' + platforms[network] + '/all.json')
        cache = args.catalog_cache / (network + '.json') if args.catalog_cache else None
        try:
            if cache and cache.exists(): raw = cache.read_bytes()
            else:
                if args.cached_only: raise ValueError('No cached public catalog')
                time.sleep(6.5)  # Preserve the app's public-provider pacing.
                request = urllib.request.Request(url, headers={'User-Agent': 'Oath-Website-Artwork-Refresh/1.0', 'Accept': 'application/json'})
                with urllib.request.urlopen(request, timeout=20) as response: raw = response.read(16 * 1024 * 1024 + 1)
            if len(raw) > 16 * 1024 * 1024: raise ValueError('Oversize public catalog')
            data = json.loads(raw); tokens = data if network == 'taiko' else data['tokens']
            if not isinstance(tokens, list) or not 0 < len(tokens) <= 25000: raise ValueError('Invalid token list')
            found = {}
            for token in tokens:
                expected = networks[network].get('chainId') if networks[network]['group'] == 'EVM' else None
                if token.get('chainId') != expected: continue
                e = entries.get((network, canonical(network, token.get('address'))))
                image = logo_url(token.get('logoURI'))
                if not e or not image: continue
                key = network + ':' + e['reference']
                if key in found and found[key] != image: raise ValueError('Conflicting artwork for one identity')
                found[key] = image
            images.update(found)
            reports.append({'network': network, 'url': url, 'sha256': hashlib.sha256(raw).hexdigest(), 'matched': len(found), 'status': 'accepted'})
        except Exception as error:
            reports.append({'network': network, 'url': url, 'status': 'unavailable', 'reason': str(error)[:200]})
            if getattr(error, 'code', None) == 429: time.sleep(60)
    # The app's batch artwork provider covers optional images omitted by lists.
    batch_platforms = {'solana':'solana','tron':'tron','sui':'sui-network','aptos':'aptos','ton':'ton','xrpl':'xrpl','near':'near','chiliz':'chiliz-chain','filecoin':'filecoin','sei':'sei-evm','zerog':'0g','iotex':'iotx'}
    batch_reports = []
    for network, platform in batch_platforms.items():
        missing = [e for e in source['entries'] if e['network'] == network and network + ':' + e['reference'] not in images]
        for offset in range(0, len(missing), 30):
            batch = missing[offset:offset+30]; refs = [e['reference'] for e in batch]
            url = 'https://api.geckoterminal.com/api/v2/networks/' + platform + '/tokens/multi/' + urllib.parse.quote(','.join(refs), safe='')
            name = network + '-batch-' + hashlib.sha256(','.join(refs).encode()).hexdigest()[:12] + '.json'
            cache = args.catalog_cache / name if args.catalog_cache else None
            try:
                if cache and cache.exists(): raw = cache.read_bytes()
                else:
                    if args.cached_only: continue
                    time.sleep(6.5)
                    request = urllib.request.Request(url, headers={'User-Agent':'Oath-Website-Artwork-Refresh/1.0','Accept':'application/json'})
                    with urllib.request.urlopen(request, timeout=20) as response: raw = response.read(2_000_001)
                    if cache: cache.write_bytes(raw)
                if len(raw) > 2_000_000: raise ValueError('Oversize batch metadata')
                rows = json.loads(raw)['data']; requested = {canonical(network, ref) for ref in refs}; seen = set(); found = {}
                if not isinstance(rows, list) or len(rows) > len(refs): raise ValueError('Unexpected artwork batch')
                for row in rows:
                    address = row['attributes']['address']; ref = canonical(network, address)
                    if row['type'] != 'token' or row['id'] != platform + '_' + address or ref not in requested or ref in seen: raise ValueError('Batch artwork identity mismatch')
                    seen.add(ref); e = entries[(network, ref)]
                    if image := logo_url(row['attributes'].get('image_url')): found[network + ':' + e['reference']] = image
                images.update(found)
                batch_reports.append({'network':network,'requested':refs,'sha256':hashlib.sha256(raw).hexdigest(),'matched':len(found),'status':'accepted'})
            except Exception as error:
                batch_reports.append({'network':network,'requested':refs,'status':'unavailable','reason':str(error)[:200]})
                if getattr(error,'code',None) == 429: time.sleep(60)
    counts = {n: sum(k.startswith(n + ':') for k in images) for n in sorted({e['network'] for e in source['entries']})}
    snapshot = {'format': 1, 'reviewed': datetime.now(timezone.utc).date().isoformat(), 'source_revision': source['revision'],
                'source_sha256': source['sha256'], 'detail_sha256': hashlib.sha256(details).hexdigest(), 'images': dict(sorted(images.items())), 'networks': counts, 'catalogs': reports, 'batches': batch_reports}
    # A failed refresh cannot silently replace an accepted catalog with less artwork.
    if accepted and len(images) < len(accepted['images']) and set(accepted['images']) <= current: raise ValueError('Artwork coverage declined; review before accepting')
    encoded = json.dumps(snapshot, separators=(',', ':'), ensure_ascii=False).encode()
    if snapshot != accepted:
        temporary = DEST.with_suffix('.next'); temporary.write_bytes(gzip.compress(encoded, compresslevel=9, mtime=0)); temporary.replace(DEST)
    print(json.dumps({'matched_entries': len(images), 'total_entries': len(source['entries']), 'networks': counts, 'unavailable_catalogs': [r['network'] for r in reports if r['status'] != 'accepted']}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog-cache', type=Path, help='Previously downloaded public token lists')
    parser.add_argument('--cached-only', action='store_true')
    refresh(parser.parse_args())

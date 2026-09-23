#!/usr/bin/env python3
"""Public, read-only Cardano checks; no keys, signatures or submitted transactions.

HTTP success alone is not a passing correctness check. Mixed-state UTXO pages
are rejected, and history paging distinguishes a bounded sample from completion.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = 'https://api.adastat.net/rest/v1'
# Public recipient from a transaction discovered through AdaStat's recent feed.
ADDRESS = 'addr1qylvn5ta29vzlzg0ygqjwta9g0wqg0jv4edypkccuzhneehe7v5mhvyvw4ftl386ezjf39kktm2tvdnpuw2s6ddfy5kseaxwut'
TOKEN_ADDRESS = 'addr1w8z0xlftcx54tn7uxdvhk0qgj9u7hmlaccjthnc9kvu4pmcyemglm'


def asset_fingerprint(policy, name_hex):
    payload = hashlib.blake2b(bytes.fromhex(policy + name_hex), digest_size=20).digest()
    acc = bits = 0
    data = []
    for value in payload:
        acc = (acc << 8) | value
        bits += 8
        while bits >= 5:
            bits -= 5
            data.append((acc >> bits) & 31)
    if bits:
        data.append((acc << (5 - bits)) & 31)
    hrp = 'asset'
    values = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp] + data + [0] * 6
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ value
        for i, generator in enumerate([0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]):
            if (top >> i) & 1:
                chk ^= generator
    chk ^= 1
    checksum = [(chk >> (5 * (5 - i))) & 31 for i in range(6)]
    alphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
    return hrp + '1' + ''.join(alphabet[n] for n in data + checksum)


def utxo_reconciliation(pages):
    rows = [row for page in pages for row in page.get('rows', [])]
    identities = [(row['tx_hash'], row['tx_index']) for row in rows]
    balances = {page['data']['balance'] for page in pages}
    complete = bool(pages) and pages[-1].get('cursor', {}).get('next') is False
    total = sum(int(row['amount']) for row in rows)
    return {'complete': complete, 'unique': len(identities) == len(set(identities)),
            'stableBalance': len(balances) == 1, 'sumLovelace': str(total),
            'reportedBalances': sorted(balances),
            'consistent': complete and len(balances) == 1 and str(total) in balances
                          and len(identities) == len(set(identities))}


class Probe:
    def __init__(self):
        self.requests = []
        self.checks = []

    def get(self, url):
        started = time.monotonic()
        row = {'url': url}
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'ApertureNetworkValidation/1.0', 'Cache-Control': 'no-cache'})
            with urllib.request.urlopen(req, timeout=20) as response:
                row['status'] = response.status
                row['response'] = json.load(response)
                row['elapsedMs'] = round((time.monotonic() - started) * 1000)
                self.requests.append(row)
                return row['response']
        except urllib.error.HTTPError as error:
            row.update(status=error.code, error=error.read().decode(errors='replace')[:500])
        except Exception as error:
            row['error'] = str(error)
        self.requests.append(row)
        return None

    def pages(self, address, kind, max_pages):
        pages = []
        cursor = None
        seen = set()
        for _ in range(max_pages):
            query = {'rows': kind, 'limit': '100'}
            if cursor:
                query['after'] = cursor
            page = self.get(BASE + '/addresses/' + address + '.json?' + urllib.parse.urlencode(query))
            if not page or page.get('code') != 200:
                raise RuntimeError('Address page unavailable; must not be interpreted as zero holdings')
            pages.append(page)
            if not isinstance(page.get('cursor', {}).get('next'), bool):
                raise RuntimeError('Missing completion marker; cannot establish complete results')
            if page['cursor']['next'] is False:
                break
            cursor = page.get('cursor', {}).get('after')
            if not cursor or cursor in seen:
                raise RuntimeError('Missing or repeated pagination cursor')
            seen.add(cursor)
        return pages

    def run(self, address, history_pages=25):
        self.get('https://api.koios.rest/api/v1/tip')  # One check; no quota bypass or retry loop.
        self.get(BASE + '/status.json')
        pages = self.pages(address, 'utxos', 25)
        self.checks.append({'name': 'funded ADA UTXO reconciliation', **utxo_reconciliation(pages)})
        history = self.pages(address, 'history', history_pages)
        hashes = [r['tx_hash'] for p in history for r in p.get('rows', [])]
        self.checks.append({'name': 'history pagination', 'rows': len(hashes),
                            'unique': len(hashes) == len(set(hashes)),
                            'complete': not history[-1].get('cursor', {}).get('next', False)})
        if hashes:
            tx = self.get(BASE + '/transactions/' + hashes[0] + '.json')
            if tx and tx.get('code') == 200:
                data = tx['data']
                incoming = sum(int(r['amount']) for r in data['outputs']['rows'] if r['address'] == address)
                outgoing = sum(int(r['amount']) for r in data['inputs']['rows'] if r['address'] == address)
                self.checks.append({'name': 'history delta vs transaction inputs and outputs',
                                    'matches': incoming - outgoing == int(history[0]['rows'][0]['amount'])})
        token_pages = self.pages(TOKEN_ADDRESS, 'tokens', 2)
        for page in token_pages:
            for token in page['rows']:
                self.checks.append({'name': 'CIP14 policy and raw-name identity',
                    'matches': asset_fingerprint(token['policy'], token['asset_name_hex']) == token['fingerprint'],
                    'quantity': str(token['quantity']), 'fingerprint': token['fingerprint']})
        token_utxos = self.pages(TOKEN_ADDRESS, 'utxos', 2)
        self.checks.append({'name': 'token-holding address ADA reconciliation', **utxo_reconciliation(token_utxos)})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--address', default=ADDRESS)
    parser.add_argument('--history-pages', type=int, default=25, help='Bounded full-history attempt; incomplete pagination is reported explicitly')
    args = parser.parse_args()
    if args.history_pages < 1:
        parser.error('--history-pages must be positive')
    probe = Probe()
    try:
        probe.run(args.address, args.history_pages)
    except Exception as error:
        probe.checks.append({'name': 'probe interrupted', 'error': str(error)})
    output = ROOT / 'docs/CardanoValidation/live-results.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'requests': probe.requests, 'checks': probe.checks,
        'fullWalletReadiness': 'NOT_ESTABLISHED'}, indent=2) + '\n')
    print(json.dumps(probe.checks, indent=2))
    print('Saved', output)

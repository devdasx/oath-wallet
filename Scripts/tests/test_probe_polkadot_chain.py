import importlib.util
import json
from decimal import Decimal
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('polkadot_probe', ROOT / 'Scripts/probe_polkadot_chain.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
FIXTURES = ROOT / 'docs/PolkadotValidation/fixtures'
ADDRESS = '134BxqvdkMzf1v95j1Wr2NmXoqpys2Y96GXG5a5H3YtMKLqf'


def fixture(name):
    return json.loads((FIXTURES / (name + '.json')).read_text())


class PolkadotValidationTests(unittest.TestCase):
    def test_raw_rpc_matches_sidecar_at_recorded_block(self):
        decoded = probe.decode_account(fixture('raw-account-same-block')['result'])
        balance = fixture('balance-0')
        for key, value in decoded.items():
            self.assertEqual(value, balance[key])
        self.assertEqual(Decimal(balance['free']) / 10**10, Decimal('1.0071900508'))

    def test_reserved_and_transferable_are_not_free_balance(self):
        balance = fixture('balance-0')
        self.assertGreater(int(balance['reserved']), int(balance['free']))
        self.assertEqual(int(balance['free']) - int(balance['transferable']), 100000000)

    def test_nonzero_token_uses_its_own_decimals(self):
        tokens = fixture('tokens-0')
        metadata = fixture('held-token-metadata')
        token = next(t for t in tokens['assets'] if t['assetId'] == '31337')
        self.assertEqual(metadata['at'], tokens['at'])
        self.assertEqual(bytes.fromhex(metadata['value']['symbol'][2:]).decode(), 'WUD')
        self.assertEqual(Decimal(token['balance']) / Decimal(10)**int(metadata['value']['decimals']), 1)

    def test_historical_transfer_matches_chain_event_in_finalization(self):
        rows = [json.loads(line) for line in (FIXTURES / 'portal-history.json').read_text().splitlines()]
        row = next(r for r in rows if r.get('events'))
        event = row['events'][0]['args']
        block = fixture('history-block-cross-check')
        self.assertEqual(row['header']['number'], int(block['number']))
        transfers = probe.block_transfers(block)
        match = next(t['data'] for t in transfers if t['data'][2] == event['amount'])
        self.assertEqual('0x' + probe.account_id(match[0]).hex(), event['from'])
        self.assertEqual('0x' + probe.account_id(match[1]).hex(), event['to'])
        self.assertIn(transfers[0], block['onFinalize']['events'])

    def test_ss58_rejects_bad_checksum(self):
        with self.assertRaises(ValueError):
            probe.account_id(ADDRESS[:-1] + '1')

    def test_account_layout_mismatch_is_not_zero(self):
        for value in [None, '0x', '0x' + '00' * 79, '0x' + '00' * 81]:
            with self.assertRaises(ValueError):
                probe.decode_account(value)

    def test_hub_genesis_is_not_relay_chain(self):
        self.assertEqual(fixture('genesis')['result'], '0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f')
        self.assertEqual(fixture('runtime')['result']['specName'], 'statemint')


if __name__ == '__main__':
    unittest.main()

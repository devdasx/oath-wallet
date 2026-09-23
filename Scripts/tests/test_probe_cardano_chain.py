import importlib.util
import json
from decimal import Decimal
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cardano_probe', ROOT / 'Scripts/probe_cardano_chain.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
FIXTURES = ROOT / 'docs/CardanoValidation/fixtures'


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


class CardanoReadinessTests(unittest.TestCase):
    def test_live_token_utxo_balance_matches_exact_integer_sum(self):
        result = probe.utxo_reconciliation([fixture('cardano-token-utxos.json')])
        self.assertTrue(result['consistent'])
        self.assertEqual(result['sumLovelace'], '1512810')

    def test_mixed_live_pages_are_never_authoritative(self):
        result = probe.utxo_reconciliation(fixture('cardano-utxo-pages.json'))
        self.assertTrue(result['complete'])
        self.assertFalse(result['consistent'])

    def test_incomplete_page_is_not_full_balance(self):
        result = probe.utxo_reconciliation([fixture('cardano-native-utxos.json')])
        self.assertFalse(result['complete'])
        self.assertFalse(result['consistent'])

    def test_duplicate_utxos_are_rejected(self):
        page = fixture('cardano-token-utxos.json')
        page['rows'] *= 2
        self.assertFalse(probe.utxo_reconciliation([page])['consistent'])

    def test_token_identity_uses_raw_asset_name_not_display_name(self):
        token = fixture('cardano-token-balances.json')['rows'][0]
        self.assertEqual(probe.asset_fingerprint(token['policy'], token['asset_name_hex']), token['fingerprint'])
        self.assertNotEqual(probe.asset_fingerprint(token['policy'], token['asset_name']), token['fingerprint'])

    def test_history_cursor_pages_do_not_overlap(self):
        first = fixture('cardano-native-history.json')['rows']
        second = fixture('cardano-history-page2.json')['rows']
        self.assertFalse({r['tx_hash'] for r in first} & {r['tx_hash'] for r in second})

    def test_detects_real_initial_indexer_lag(self):
        recent = fixture('cardano-native-tx.json')['data']
        initial = fixture('cardano-stable-history.json')
        self.assertGreater(recent['time'], initial['data']['last_tx_time'])
        self.assertNotIn(recent['hash'], {r['tx_hash'] for r in initial['rows']})
        later = fixture('cardano-history-consistency.json')['addressResponse']
        self.assertIn(recent['hash'], {r['tx_hash'] for r in later['rows']})

    def test_missing_cursor_cannot_establish_complete_balance(self):
        page = fixture('cardano-token-utxos.json')
        page.pop('cursor')
        self.assertFalse(probe.utxo_reconciliation([page])['consistent'])

    def test_fungible_token_matches_holder_record_and_decimals(self):
        holders = fixture('cardano-fungible-holders.json')
        inventory = fixture('cardano-fungible-balance.json')
        token = next(r for r in inventory['rows'] if r['fingerprint'] == holders['data']['fingerprint'])
        holder = next(r for r in holders['rows'] if r['address'] == inventory['data']['address'])
        self.assertEqual(int(token['quantity']), int(holder['quantity']))
        self.assertEqual(probe.asset_fingerprint(token['policy'], token['asset_name_hex']), token['fingerprint'])
        self.assertEqual(Decimal(token['quantity']) / Decimal(10) ** token['decimals'], Decimal('660000000'))

    def test_complete_recorded_history_reconciles_native_balance(self):
        pages = fixture('cardano-full-history.json')
        self.assertIs(pages[-1]['cursor']['next'], False)
        rows = [r for p in pages for r in p['rows']]
        self.assertEqual(len(rows), 1839)
        self.assertEqual(len({r['tx_hash'] for r in rows}), len(rows))
        self.assertEqual(sum(int(r['amount']) for r in rows), int(pages[-1]['data']['balance']))


if __name__ == '__main__':
    unittest.main()

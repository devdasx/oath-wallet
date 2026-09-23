#!/usr/bin/env python3
"""Run with Electrum 4.8.1 on PYTHONPATH. Offline, PUBLIC mainnet-format keys.
Never fund these wallets. Output must be a new directory. No nodes are contacted.
"""
import argparse
import copy
import json
import tempfile
from pathlib import Path
from electrum import bitcoin, keystore, version
from electrum.simple_config import SimpleConfig
from electrum.storage import WalletStorage, StorageEncryptionVersion
from electrum.wallet_db import WalletDB
from electrum.wallet import Standard_Wallet, Imported_Wallet, Wallet
from electrum.util import create_and_start_event_loop


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    output = parser.parse_args().output
    output.mkdir(parents=True, exist_ok=False)
    assert version.ELECTRUM_VERSION == '4.8.1'
    loop, stop, thread = create_and_start_event_loop()
    manifest = []
    password = 'ElectrumFixture-é-测试'
    try:
        with tempfile.TemporaryDirectory() as temp:
            config = SimpleConfig({'electrum_path': temp})

            def emit(name, ks, imported=False):
                db = WalletDB('', storage=None, upgrade=True)
                db.put('wallet_type', 'imported' if imported else 'standard')
                db.put('keystore', ks.dump())
                db.put('gap_limit', 27)
                db.put('gap_limit_for_change', 9)
                wallet = (Imported_Wallet if imported else Standard_Wallet)(db, config=config)
                if imported:
                    secret = bytes.fromhex('11' * 32)
                    keys = [bitcoin.serialize_privkey(secret, True, t) for t in ('p2pkh', 'p2wpkh', 'p2wpkh-p2sh')]
                    keys += [bitcoin.serialize_privkey(bytes.fromhex('22' * 32), False, 'p2pkh')]
                    good, bad = wallet.import_private_keys(keys, None)
                    assert len(good) == 4 and not bad
                else:
                    wallet.synchronize()
                refs = []
                if imported:
                    for address in wallet.get_addresses():
                        refs.append({'branch': 0, 'index': 0, 'address': address,
                                     'wif': wallet.export_private_key(address, None)})
                else:
                    for branch in (0, 1):
                        for index in (0, 1, 8, 26, 100, 1000):
                            address = wallet.derive_address(branch, index)
                            key, compressed = ks.get_private_key([branch, index], None)
                            refs.append({'branch': branch, 'index': index, 'address': address,
                                         'wif': bitcoin.serialize_privkey(key, compressed, wallet.txin_type)})
                original = json.loads(db.dump())
                for mode in ('clear', 'keys-encrypted', 'file-encrypted'):
                    data = copy.deepcopy(original)
                    if mode != 'clear':
                        # Use Electrum's own keystore password handling.
                        encrypted_ks = keystore.load_keystore(WalletDB(json.dumps(data), storage=None, upgrade=True), 'keystore')
                        encrypted_ks.update_password(None, password)
                        data['keystore'] = encrypted_ks.dump()
                        data['use_encryption'] = True
                    filename = name + '-' + mode + '.wallet'
                    storage = WalletStorage(str(output / filename))
                    if mode == 'file-encrypted':
                        storage.set_password(password, StorageEncryptionVersion.USER_PASSWORD)
                    storage.write(json.dumps(data, sort_keys=True, indent=2))
                    # Reopen and verify with Electrum, not just the construction data.
                    opened = WalletStorage(str(output / filename))
                    if opened.is_encrypted():
                        opened.decrypt(password)
                    restored = (Imported_Wallet if imported else Standard_Wallet)(
                        WalletDB(opened.read(), storage=None, upgrade=True), config=config)
                    assert restored.get_addresses() == wallet.get_addresses()
                    if mode != 'clear':
                        restored.keystore.check_password(password)
                    manifest.append({'name': filename, 'password': '' if mode == 'clear' else password,
                                     'kind': 'imported' if imported else 'standard', 'references': refs})
                if name == 'custom-5-p2wpkh':
                    filename = 'journal.wallet'
                    storage = WalletStorage(str(output / filename), allow_partial_writes=True)
                    journal_db = WalletDB(json.dumps(original), storage=storage, upgrade=True)
                    journal_db.set_modified(True)
                    journal_db.write_and_force_consolidation()
                    storage = WalletStorage(str(output / filename), allow_partial_writes=True)
                    journal_db = WalletDB(storage.read(), storage=storage, upgrade=True)
                    journal_db.put('gap_limit', 31)
                    journal_db.put('labels', {'fixture': 'public test'})
                    journal_db.write()
                    raw = storage.read()
                    assert '\"op\"' in (output / filename).read_text()
                    reloaded = WalletDB((output / filename).read_text(), storage=None, upgrade=True)
                    assert reloaded.get('gap_limit') == 31
                    manifest.append({'name': filename, 'password': '', 'kind': 'standard', 'references': refs})

            for i, path in enumerate(('m', "m/0'", "m/44'/0'/7'", "m/49'/0'/11'", "m/84'/0'/3'", "m/7'/12/9'/4/18'")):
                for script in ('standard', 'p2wpkh-p2sh', 'p2wpkh'):
                    ks = keystore.BIP32_KeyStore({})
                    ks.add_xprv_from_seed(bytes(range(32)), xtype=script, derivation=path)
                    emit(f'custom-{i}-{script}', ks)
            for name, seed in (
                ('electrum-standard', 'cycle rocket west magnet parrot shuffle foot correct salt library feed song'),
                ('electrum-segwit', 'bitter grass shiver impose acquire brush forget axis eager alone wine silver'),
                ('electrum-old', 'powerful random nobody notice nothing important anyway look away hidden message over'),
            ):
                emit(name, keystore.from_seed(seed, passphrase='', for_multisig=False))
            emit('imported-mixed', keystore.Imported_KeyStore({}), imported=True)
            historical = []
            reference_dir = Path(__import__('electrum').__file__).parent.parent / 'tests/test_storage_upgrade'
            names = ['client_1_9_8_seeded']
            for release in ('2_0_4', '2_1_1', '2_2_0', '2_3_2', '2_4_3', '2_5_4', '2_6_4', '2_7_18', '2_8_3', '2_9_3'):
                names += [f'client_{release}_seeded', f'client_{release}_importedkeys']
            for name in names:
                path = reference_dir / name
                if not path.exists():
                    continue
                raw = path.read_text()
                db = WalletDB(raw, storage=None, upgrade=True)
                restored = Wallet(db, config=config)
                restored.synchronize()
                refs = []
                imported = isinstance(restored, Imported_Wallet)
                if imported:
                    for address in restored.get_addresses():
                        refs.append({'branch': 0, 'index': 0, 'address': address,
                                     'wif': restored.export_private_key(address, None)})
                else:
                    for branch in (0, 1):
                        for index in (0, 1, 20, 100):
                            key, compressed = restored.keystore.get_private_key([branch, index], None)
                            refs.append({'branch': branch, 'index': index,
                                         'address': restored.derive_address(branch, index),
                                         'wif': bitcoin.serialize_privkey(key, compressed, restored.txin_type)})
                (output / (name + '.wallet')).write_text(raw)
                historical.append({'name': name + '.wallet', 'kind': 'imported' if imported else 'standard',
                                   'password': '', 'references': refs})
            (output / 'historical-manifest.json').write_text(json.dumps(historical, indent=2) + '\n')
            (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
            (output / 'README.md').write_text('# Public Electrum fixtures\n\nGenerated offline by Electrum 4.8.1. Never send funds to these public test keys.\n\nRegenerate with `Scripts/generate_electrum_import_fixtures.py` using the pinned Electrum source on PYTHONPATH. Password: `ElectrumFixture-é-测试`. Fixtures cover saved root/account/custom BIP32 nodes, Electrum standard/SegWit/old seeds, mixed imported keys, plaintext, inner encryption, whole-file encryption, and appended JSON patches. `manifest.json` records Electrum-derived receiving/change addresses and public test WIFs at indices through 1000.\n')
            print(f'Generated/reopened {len(manifest)} new and {len(historical)} historical mainnet-format Electrum fixtures.')
    finally:
        loop.call_soon_threadsafe(stop.set_result, 1)
        thread.join()


if __name__ == '__main__':
    main()

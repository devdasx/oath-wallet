# Public Electrum fixtures

Generated offline by Electrum 4.8.1. Never send funds to these public test keys.

Regenerate with `Scripts/generate_electrum_import_fixtures.py` using the pinned Electrum source on PYTHONPATH. Password: `ElectrumFixture-é-测试`. Fixtures cover saved root/account/custom BIP32 nodes, Electrum standard/SegWit/old seeds, mixed imported keys, plaintext, inner encryption, whole-file encryption, and appended JSON patches. `manifest.json` records Electrum-derived receiving/change addresses and public test WIFs at indices through 1000.

The 21 `client_*` historical mainnet files are public fixtures from Electrum 4.8.1 `tests/test_storage_upgrade`, covered by the Electrum MIT notice in `docs/BitcoinImportLicense.txt`. They are reopened by Electrum to generate `historical-manifest.json`. No historical testnet files are included.

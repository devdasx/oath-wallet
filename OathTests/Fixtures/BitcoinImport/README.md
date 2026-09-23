# Bitcoin Core import fixtures

These files are public, deliberately unfunded test wallets. Never send funds to them.

Generated with the official Bitcoin Core **28.3 arm64 macOS** release, verified
against its published SHA256SUMS. The daemon used mainnet serialization and
network parameters, with networking disabled (`-connect=0 -listen=0 -dnsseed=0
-discover=0 -networkactive=0`). No transactions were created or broadcast.

`descriptor-*` are SQLite descriptor wallets; `legacy-*` are Berkeley DB legacy
wallets. Both families include a clear and an encrypted backup. The encrypted
fixtures use the public test password `CoreTestPassword`. Matching `listdescriptors
true` JSON and `dumpwallet` TXT exports provide independent representations.
`manifest.json` records addresses returned directly by Core, including change.

Reproduction: `Scripts/generate_bitcoin_import_fixtures.py` accepts a verified Core
28.3 binary directory and a new temporary output directory. It creates fresh,
random fixture keys; therefore new byte contents/addresses will differ. It never
uses the user's Bitcoin data directory or connects to the network.

References:
- https://bitcoincore.org/bin/bitcoin-core-28.3/
- https://github.com/bitcoin/bitcoin/blob/v28.3/src/wallet/walletdb.cpp
- https://github.com/bitcoin/bitcoin/blob/master/src/wallet/migrate.cpp
- https://github.com/bitcoin/bitcoin/blob/master/doc/descriptors.md
- https://www.sqlite.org/fileformat.html

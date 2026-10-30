# Bitcoin-family discovery and receive addresses

Current release: [4.1.14 (98) verification record](../../releases/4.1.14.md). Historical checks below describe their original scope; they are not an independent audit of this release.


Bitcoin, Dogecoin, Litecoin and Bitcoin Cash balance/history retrieval is enabled. Native Bitcoin, Bitcoin Cash, Litecoin and Dogecoin sending, signing and broadcast are connected to the app's Send flow. The existing package and database names are retained to avoid breaking Bitcoin integrations.

## Fee APIs (verified 2026-10-13)

The app injects the locally configured ANKR credential into one shared `UTXOFeeProvider`.
Bitcoin first requests ANKR's [estimatesmartfee](https://www.ankr.com/docs/rpc-service/chains/chains-api/btc/raw-transactions-rpcs-p2/), using a three-block conservative target.
Decimal BTC/kVB becomes integer sat/kVB, rounded upward and checked against the send policy.
An error, missing estimate, invalid response or a 750 ms deadline starts the existing public API race (mempool.space first).
Both API stages share the five-second budget; only after API exhaustion may the existing three-second server fallback start.
The 30-second cache and in-flight coalescing remain per chain. Provider failures use the shared diagnostics outbox and privacy filters.

Litecoin mainnet was [retired by ANKR on September 15](https://www.ankr.com/docs/changelog/chain-list-cleanup-2026-09-15/).
That announcement retains Dogecoin mainnet, but the configured account's Dogecoin request returned HTTP 403; it is not enabled as a primary fee source.
Bitcoin Cash has no endpoint in the current [ANKR chain catalog](https://www.ankr.com/web3-api/chains-list/).
These three chains keep their existing public fee APIs without an extra ANKR delay.

`AnkrUTXOFeeTests` covers requests, unit conversion, invalid/error envelopes, credential filtering and the verified chain restriction.
`UTXOFeeProviderTests` covers primary success, immediate failure, timeout cancellation, cache/coalescing and last-resort ordering on all four chains.
The opt-in `testLiveConfiguredAnkrAndAllChainFallbacks` reads `OATH_RPC_CONFIGURATION_PATH` when `OATH_ANKR_FEES_LIVE=1`;
it never prints the credential and only requests fees. The October 13 run returned valid fees in 90 ms (BTC), 300 ms (DOGE),
361 ms (LTC), and 426 ms (BCH); two direct ANKR requests took 296 ms and 99 ms. These are observations, not latency guarantees.
No transaction was signed or broadcast by this test.

## Keys and address types

`BitcoinKeys` delegates secp256k1, BIP32, script construction and address encoding to pinned Bitcoin Dev Kit 3.1.1. Mnemonic wallets use the existing WalletCore BIP39 seed, including the wallet's passphrase. Master keys derive `m/{86,84,49,44}'/0'/account'/{0,1}/index`.

- Mnemonic/master xprv/yprv/zprv: Taproot, native SegWit, nested SegWit, legacy; receive and change branches.
- Account/branch extended keys: derive only descendants of the imported key. A hardened sibling cannot be recovered from an account key. The Receive picker explains this scope. SLIP132 prefixes choose the initial type; switching type wraps the same imported branch. Root public keys cannot derive hardened accounts; account xpub/ypub/zpub are supported by the public derivation API for tests and future watch-only work.
- Compressed WIF/hex: one address for each of the four script types. An individual private key has no HD chain code and cannot produce 20 distinct addresses per type.
- Uncompressed WIF: one legacy P2PKH address only. Compression and extended-key material survive encrypted local and cloud backup round trips; old readers reject the new envelope versions.

Private material stays in the vault/crypto boundary. Only public descriptors, addresses, scripts and transaction data enter the database. Only script hashes and public transaction IDs enter Electrum requests; xpubs, mnemonics and private keys are never sent to Electrum.

### Dogecoin keys

`DogecoinKeys` uses the same pinned BDK curve/BIP32/script primitives. Dogecoin uses P2PKH (address prefix 30, WIF 158), with `m/44'/3'/account'/{0,1}/index` for BIP39 mnemonic wallets, including their BIP39 passphrase. SegWit and Taproot are not offered on Dogecoin.

- Compressed and uncompressed mainnet Dogecoin WIF preserve their public-key compression and exact address.
- Raw 32-byte hex (optional `0x`) and canonical Base64 import as compressed keys. Testnet WIF, bad checksums, invalid scalars and BIP38 encrypted keys are rejected.
- Root/ancestor/account/branch/leaf dgpv or xprv retain the chain code and derive only descendants within the supplied scope. Account dgub/xpub are supported by the public descriptor API for reference tests and future watch-only support, not by the private-key import screen.
- A finite private key produces one address; it is not misrepresented as an HD wallet. HD wallets scan both receive and change with a gap of 20. Imported change-only branches remain limited to their supplied descendants.
- Local envelope v6 and cloud backup v4 preserve extended keys and uncompressed WIF. Older readers reject these formats instead of silently restoring a different wallet. Earlier envelope/backup versions remain readable.
- Import/restore deduplication compares key scope and compression as well as the scalar. The same scalar with a different chain code, or compressed versus uncompressed WIF, cannot select the wrong wallet. Equivalent dgpv/xprv prefixes still deduplicate.

### Dogecoin Send (2026-10-13)

Dogecoin now uses the shared Send review, vault authorization, combined UTXO selection, durable reservation/signature journal and retry/reconciliation flow. All app-supported Dogecoin sources are P2PKH: HD receive/change paths, scoped dgpv/xprv imports, and compressed/uncompressed individual keys. Destinations are checksum-verified Dogecoin P2PKH or P2SH. SegWit/Taproot destinations and witness transaction encodings are rejected. Mainnet, testnet and regtest use distinct address rules; the app only submits mainnet plans, while isolated tests explicitly select test networks.

The planner preserves the requested amount whenever economic inputs cover it plus the fee. Otherwise it reduces the recipient amount on review before authorization. Tiny unselected outputs may remain in the wallet. Change below 0.01 DOGE is folded into the displayed fee; recipient outputs down to Core's 0.001 DOGE hard limit are supported, with the extra 0.01 DOGE soft-dust fee when required. Fee estimation is rounded upward in atomic units, with Core's recommended 0.01 DOGE/kB floor; a missing estimate can fall back to a verified peer's relay quote plus this floor. The transaction/output limit is 10 billion DOGE, while aggregate wallet balances use checked Int64 arithmetic independently of that limit.

Independent fee and account discovery work overlaps. Authorization, signing, saving signed bytes and broadcasting stay ordered. A lost broadcast response retains input reservations and reconciles/retries only identical signed bytes. The UI provides review/retry/checking states without displaying provider exception text. Migration v32 preserves queued BTC/BCH/LTC diagnostics and adds Dogecoin; enum-only events go to the bounded local diagnostic outbox. No keys, addresses, wallet IDs or transaction payloads are included.

Verification evidence is in `Verification/dogecoin-send-2026-10-13.json`. Host tests cover fee/dust boundaries, large balances, overflow, both HD branches, all supported private-key scopes, compression, duplicate/forged inputs, expired/modified review, and transport failover. An isolated official Dogecoin Core 1.14.9 node with standard policy accepts and mines a 24-transaction matrix, including 255 mixed inputs to P2PKH and P2SH. The node rejects an altered signed recipient output. Regtest acceptance is **not** public-testnet or mainnet broadcast evidence.

Reproduce host tests with `swift test --package-path Packages/OathBitcoin --filter Dogecoin`. Core checks require `OATH_DOGE_REGTEST=1` and a network-isolated container named `oath-doge-send-regtest`, running `/doge/dogecoind -regtest -server -txindex -acceptnonstdtxn=0 -rpcuser=oathregtest -rpcpassword=isolated-test-only`; the matching CLI must be `/doge/dogecoin-cli`. These credentials belong only to the isolated disposable test node. The official aarch64 1.14.9 archive SHA-256 is `6928c895a20d0bcb6d5c7dcec753d35c884a471aaf8ad4242a89a96acb4f2985`.

Public-testnet preparation uses `OATH_DOGE_TESTNET_DIR=/tmp/oath-doge-public` with `testPrepareIsolatedPublicTestWallet`, keeping its new seed locally at mode 0600. Fund only its public testnet address, then run `Tools/dogecoin-testnet.py <directory> fetch`, `testSignPublicTestnetTransfer` with `OATH_DOGE_PUBLIC_SIGN_DIR=<directory>`, followed by the tool's `broadcast` and `verify` modes. The tool checks testnet genesis before requests, verifies returned bytes and confirmed Merkle inclusion, and supports a supplied HTTPS Esplora endpoint through `OATH_DOGE_TESTNET_API`. The public testnet run remains blocked on available funding/API access; no public-testnet broadcast is claimed. No simulator or physical device was launched, and no mainnet transfer was made.

Policy references: [Dogecoin Core 1.14.9 policy](https://github.com/dogecoin/dogecoin/blob/v1.14.9/src/policy/policy.h), [amount bounds](https://github.com/dogecoin/dogecoin/blob/v1.14.9/src/amount.h), [network parameters](https://github.com/dogecoin/dogecoin/blob/v1.14.9/src/chainparams.cpp), [fee recommendations](https://github.com/dogecoin/dogecoin/blob/v1.14.9/doc/fee-recommendation.md).

### Litecoin keys and Receive

`LitecoinKeys` uses the same BDK primitives for curve operations, BIP32, public descriptors and scripts, with Litecoin-specific network encodings. BIP39 mnemonic/passphrase wallets derive `m/{86,84,49,44}'/2'/account'/{0,1}/index`. Receive offers Taproot, native SegWit, nested SegWit and Legacy. The saved Receive choice does not filter discovery or the combined spending pool.

- Mainnet compressed/uncompressed WIF (`0xb0`), 32-byte hex, canonical Base64, valid Casascius mini keys, Electrum-LTC single-key WIF prefixes, and xprv/yprv/zprv/Ltpv/Mtpv extended private keys are accepted. Uncompressed/mini keys offer Legacy only; raw keys stay finite. BIP38 encrypted keys are not supported.
- Public account xpub/ypub/zpub/Ltub/Mtub derivation is available for reference checks and future watch-only import. Public keys are not accepted by the private-key entry screen. Hardened ancestors/siblings cannot be reconstructed from a scoped account/branch key.
- P2PKH uses prefix 48, nested SegWit uses prefix 50, and witness addresses use `ltc1` with Bech32/Bech32m checksums. Old `3...` P2SH aliases lock the same script; no extra balance scan or duplicate coin is created for an address spelling.
- Local envelope v7 and cloud backup v5 retain uncompressed and extended Litecoin material. Old readers reject these versions. Equivalent version-prefix aliases deduplicate; different chain codes or compression remain different wallets. Earlier backup formats remain readable.
- The transparent ledger accepts both ordinary serialized transactions and Litecoin's MWEB-bearing public transaction envelope. It checks the public txid, output script and value; it does not validate confidential MWEB proofs or derive `ltcmweb` wallets. The first HogEx output's version-8 script identifies peg-outs even if a server strips the MWEB flag. Peg-outs remain in the displayed balance immediately but require six confirmations before reservation; ordinary pending incoming/change outputs stay eligible at zero confirmations.

Litecoin's pool uses system-trust TLS to `electrum1.cipig.net:20063` and `electrum2.cipig.net:20063`. Both passed mainnet genesis, 300-request batch, empty response and real historical transaction checks. These are separate hosts operated by the same provider; they are not independent consensus verification. A third refusing endpoint and peers with invalid certificates are excluded. No silent plaintext or certificate-verification downgrade is used.

The shared indexed ledger stores network-scoped addresses, history, confirmed/pending balances, funding transactions and reservations. `bitcoinSpendableOutputs(walletID:network: .litecoin)` provides the combined Litecoin pool for Send. No additional balance source or per-type ledger is introduced.

### Litecoin Send (2026-10-13)

The shared planner, vault signer, reservation journal and recovery service now support Litecoin. Mainnet destinations are decoded with Litecoin's version bytes and Bech32/Bech32m checksums. Legacy, nested SegWit, native SegWit and Taproot inputs can be mixed across receive/change paths. Scoped extended-key imports and compressed/uncompressed individual keys retain their original derivation restrictions. Mature transparent MWEB withdrawals are spendable; confidential MWEB wallets and MWEB destinations are outside this implementation.

Selection preserves the requested recipient amount whenever an economical input selection covers the fee. Otherwise review shows the reduced recipient amount before authorization. A wallet remainder below dust is allowed, but a new change output below the selected script's Litecoin dust threshold is never created. Litecoin uses its own 84-million supply bound and 30 sat/vB dust relay policy, rather than Bitcoin's supply/dust limits. Excess sub-dust change is included in the displayed fee.

Fee lookup and independent discovery requests overlap. Authorization, signing, durable journaling and broadcasting remain ordered; broadcasting cannot start before signed bytes and reservations are saved. A lost response retains reservations and retries the identical transaction. The UI provides retry/review or checking status without exposing provider error messages. Sanitized enum-only diagnostics are retained locally without a remote upload transport; keys, wallet identities, addresses and transaction payloads are excluded. Migration v31 preserves queued Bitcoin/BCH diagnostic events.

Verification reached:

- Generic iOS Debug build passed; no simulator or physical-device launch.
- Targeted Bitcoin/BCH/Litecoin/key/transport regression: 51 passed, 13 opt-in checks skipped. The live Litecoin fee check was enabled and passed.
- Database regression: 15 passed, including Litecoin signed-journal reopen, reservation retention, mined-conflict settlement, MWEB maturity and diagnostic migration preservation.
- Litecoin Core 0.21.5.8 regtest: 44 sends accepted, identically rebroadcast and mined. Covers every source/destination type, both HD branches, uncompressed imports, 255 mixed inputs, fee deduction, dust boundaries, legacy P2SH aliases and P2WSH destinations. A modified signed recipient amount was rejected by script validation.
- Public Litecoin testnet: six transfers signed by the production Swift signer were accepted and mined in block 4,912,858. Includes mixed inputs and spends from all four address types. Raw bytes and Merkle inclusion proofs matched on both official Electrum-LTC testnet servers. One server rejected an unconfirmed Taproot spend; the other accepted identical bytes, and both later returned its confirmed inclusion proof.
- Both configured mainnet peers passed read-only discovery, batching, history and funding-transaction checks. No mainnet broadcast was performed.

Public transaction receipts and precise check counts are saved in `Verification/litecoin-send-2026-10-13.json`. These results do not constitute an exhaustive proof against every possible network/device failure. Simulator UI, physical-device authentication and a mainnet send remain untested.

Host tests use `swift test --package-path Packages/OathBitcoin --filter LitecoinSendTests`. The Core matrix is opt-in with `OATH_LTC_REGTEST=1` and expects the isolated `oath-ltc-send-regtest` container exposing `/ltc/litecoin-cli` with regtest data at `/data` and wallet `oath-ltc-send`; the node must enable `txindex=1` and `acceptnonstdtxn=0`. The verified aarch64 Core 0.21.5.8 release archive SHA-256 is `129f55defb9045d5635566382c7b9f6fd227d4106a6fc07847a38b25ff9b29a1`.

Public tests use `OATH_LTC_TESTNET_DIR` to create a fresh isolated test-only seed locally and `OATH_LTC_PUBLIC_SIGN_DIR` to sign after `Tools/litecoin-testnet.py <directory> fetch`. The tool's `broadcast` command submits only the saved signed bytes; `verify` checks block inclusion on both peers. Its explicit `--trust-first-use` option pins the official testnet servers' self-signed certificates, following Electrum's test-server trust model. Production mainnet connections retain system-trust TLS. Never use a real wallet's seed or export the test seed into logs, source control or diagnostics.

Litecoin primary references: [Core network parameters](https://github.com/litecoin-project/litecoin/blob/ec1b6489a900d09cf5991e220dce089c77a232a2/src/chainparams.cpp), [Core maturity rules](https://github.com/litecoin-project/litecoin/blob/ec1b6489a900d09cf5991e220dce089c77a232a2/src/consensus/consensus.h), [Core transaction serialization](https://github.com/litecoin-project/litecoin/blob/ec1b6489a900d09cf5991e220dce089c77a232a2/src/primitives/transaction.h), [Electrum-LTC WIF formats](https://github.com/pooler/electrum-ltc/blob/f9cbfaca5f8b2ab3eef89758bf78b7e4c2c554a0/electrum_ltc/bitcoin.py), [SLIP132](https://github.com/satoshilabs/slips/blob/master/slip-0132.md).

### Bitcoin Cash keys and Receive

`BitcoinCashKeys` implements BIP44 coin 145: `m/44'/145'/account'/{0,1}/index`. The shared BIP39 seed path retains mnemonic language/passphrase handling. BCH generates P2PKH CashAddr with the `bitcoincash:` prefix in Receive/copy/QR; it never offers Bitcoin SegWit or Taproot addresses. Legacy Base58 and CashAddr spellings identify the same script, so they do not create extra balances or UTXOs.

- Imports support compressed/uncompressed mainnet WIF (`0x80`), raw 32-byte hex (optional `0x`/`0X`), canonical Base64, validated Casascius/Electron Cash mini keys, `p2pkh:` WIF, and standard xprv root/purpose/coin/account/branch/leaf keys. Mini keys remain uncompressed; raw keys remain finite. Standard account/branch/leaf xpub derivation is available through the public descriptor API for watch-only infrastructure and tests, not through the private-key import screen. BIP38 encrypted keys, testnet keys, multisig-only exports and SegWit-specific y/z prefixes are rejected.
- Root mnemonic/xprv defaults to BIP44/145. An account/branch xprv retains its supplied subtree, including externally derived accounts; it cannot reconstruct unavailable hardened siblings. Old Electron Cash seed schemes and automatic discovery of arbitrary legacy derivation paths are not claimed.
- Local encrypted envelope v8 and cloud backup v6 preserve BCH extended keys and compression; previous formats remain readable. Old app readers reject these versions. Chain code and compression participate in import/restore identity so an HD root cannot be mistaken for its finite scalar.
- Both HD branches scan concurrently, in history-based gaps of 20. Compressed/uncompressed WIF scan one address. Pending incoming BCH and change are eligible for the later ordinary-BCH spending pool; coinbase maturity is 100 confirmations. Confirmed plus signed pending delta feeds the same native/fiat display cache as the other registered networks.
- The independent TLS pool uses `electron.jochen-hoenicke.de:51002`, `bch.imaginary.cash:50002`, and `bch0.kister.net:50002`. It requires batch replies and Electrum Cash protocol 1.5. BCH shares Bitcoin's genesis, so the handshake additionally hashes BCHN checkpoint 792773 and checks the peer's tip is beyond it. This rejects Bitcoin, BSV and eCash peers despite shared early history. It is chain identification, not SPV proof of every tip or transaction.
- Both balance and unspent requests explicitly use `include_tokens`. The raw funding txid commits to any CashTokens prefix; bounded prefix decoding matches the remaining locking script. BCH satoshis on token-bearing outputs are counted and cached, but those outputs are excluded from the ordinary spending pool and from the older paged-output API to prevent a future BCH send from destroying tokens. Token transfer/NFT UI is not implemented. Standard CashAddr is used rather than signaling token-aware Receive support.
- Shared network/account-indexed tables atomically persist the complete scan, history, balances, funding bytes, used/issued address indices and reservations. BCH and BTC outputs remain isolated even when scripts and pre-fork txids coincide. Incomplete, failed, cancelled or inconsistent requests cannot publish an empty successful balance; the last good balance remains cached and spending waits for a fresh successful scan.

BCH references: [BCHN network parameters and checkpoints](https://github.com/bitcoin-cash-node/bitcoin-cash-node/blob/07576013c91ff4a3a74acd85f189c69121cdad1b/src/chainparams.cpp), [BCHN maturity and transaction-size rules](https://github.com/bitcoin-cash-node/bitcoin-cash-node/blob/07576013c91ff4a3a74acd85f189c69121cdad1b/src/consensus/consensus.h), [CashAddr specification](https://github.com/bitcoincashorg/bitcoincash.org/blob/master/spec/cashaddr.md), [Electrum Cash protocol](https://electrum-cash-protocol.readthedocs.io/en/latest/protocol-methods.html), [CashTokens encoding](https://cashtokens.org/docs/spec/chip/), [Electron Cash key formats](https://github.com/Electron-Cash/Electron-Cash/blob/257472a7ceecd088fbc83482dd19ab86c85015e9/electroncash/bitcoin.py).

## Discovery and transport

Every HD branch advances in 20-address batches until 20 consecutive addresses have **no history**, including spent addresses in the history check. Previously used/issued indices are retained across restarts. All types and both branches run concurrently, independently of the visible Receive choice. The current receive address is reused until used; reopening the sheet does not exhaust the gap.

The pool uses verified system-trust TLS to `electrum.jhoenicke.de:50002` and `electrum.diynodes.com:50022`. Both were tested with 300-request batches. Blockstream's tested endpoints disconnected on larger batches and are excluded; self-signed peers are not silently trusted. Public peer availability and limits can change.

Dogecoin has an independent pool for `dogecoin.stackwallet.com:50022`, `electrum1.cipig.net:20060` and `electrum2.cipig.net:20060`. All three passed TLS, mainnet-genesis and 300-request batch checks. Up to three leases per network run concurrently, while each connection serializes its frames. Swift task groups overlap networks, HD branches and independent chunks; no unbounded fan-out is used. AuxPoW headers may exceed Bitcoin's 80 bytes; the parser accepts the extended header while comparing the first 80 bytes for stable block identity. Coinbase outputs require 240 confirmations. Amounts use checked integer arithmetic; Dogecoin's ten-billion-coin transaction/output limit is not incorrectly used as a wallet-total cap.

Each address batches `get_balance`, `get_history` and `listunspent`. Requests are bounded to 300 per batch (100 addresses); raw funding transactions use batches of at most 40. There is one request per leased peer, bounded concurrent leases, 12-second exchanges, peer rotation, cooldowns and cancellation. Capacity is measured, not assumed to be 10,000 addresses. Handshakes verify the mainnet genesis and support for JSON batch replies. Diagnostics contain only peer names, request counts and typed failures.

Empty replies are successful **only** after a valid, complete response. Missing/duplicate IDs, malformed values, inconsistent totals, unsupported batches, TLS/network errors and timeouts fail or rotate peers. A failed branch cannot replace an account's previous successful snapshot. A changing chain tip retries the whole scan. A hard 100,000-index safety boundary fails explicitly instead of silently truncating discovery.

Electrum remains a trusted history/unspent index. Hashing each funding transaction and matching its exact script/value is not SPV proof of confirmation or of an output remaining unspent. The future Send implementation must refresh and perform its own final transaction/fee checks.

## Database and later Send flow

`OathDatabase.BitcoinLedger` uses migration v10 with indexed `bitcoinWallets`, `bitcoinAddresses`, `bitcoinHistory` and `bitcoinTransactions` tables. Atomic commits update the existing balance and UTXO ledger, preserve reservations, remove spent outputs, and replace history with the latest scan. A scan token rejects superseded results. Reset triggers fence late writes; reset erases wallet data and retains prices/preferences.

These tables also hold Dogecoin, Litecoin and Bitcoin Cash records under their account IDs and network-tagged public descriptors. Global UTXO identity includes the network; even identical scripts and transaction IDs across Bitcoin, Dogecoin, Litecoin and Bitcoin Cash cannot share balances, spent state or reservations. No duplicate Dogecoin database or separate source of truth is introduced.

`bitcoinSpendableOutputs(walletID:)` returns the combined pool across **all** Bitcoin accounts, types and change branches, with address/path/type/index, exact integer satoshis and validated funding transaction bytes. It rejects stale/in-progress/failed scans and excludes reserved/spent outputs and coinbase outputs with fewer than 100 confirmations. `queueSend` reserves selected inputs atomically across those accounts, sharing reservations between duplicate imports. No sending UI or broadcasting was added.

`dogecoinSpendableOutputs(walletID:)` returns the same validated pool for all Dogecoin accounts and branches, with Dogecoin's maturity rule. Transaction history includes spent-address history and pending/confirmed status; raw funding transactions are hash/script/value-checked before their outputs can enter the pool. The history list is paginated from local storage.

### Confirmed and pending funds

The displayed balance is **confirmed + the signed unconfirmed delta**, in exact atomic units. Pending incoming payments increase the total immediately after a successful sync. Pending spends subtract the consumed inputs and add any change; a negative pending delta must never be clamped to zero. Home, asset details, fiat conversion and cached reads all use this same committed total.

`UTXONetwork.permitsSpending` permits ordinary outputs at zero confirmations on Bitcoin, Bitcoin Cash, Litecoin and Dogecoin, including incoming payments and change whose parent is also unconfirmed. Send review and atomic input reservation both use this shared pool; there is no confirmed-only selection mode. The shared ledger still excludes spent/reserved inputs and immature mining rewards (100 confirmations on Bitcoin/Litecoin/Bitcoin Cash, 240 on Dogecoin; Litecoin MWEB peg-outs also require six confirmations). Pending outputs must have verified funding bytes and a fresh, complete scan before they can be reserved. Eligibility does not guarantee confirmation or relay acceptance.

Electrum history height `-1` means an unconfirmed transaction with unconfirmed parents; `listunspent` still reports those outputs at height `0`. Mismatched history/output heights trigger retry, even when the amounts match. A complete replacement snapshot removes dropped/replaced outputs, updates confirmations without adding the value a second time, preserves reservations and survives reopening the database. Failed scans retain the previous display balance but block new reservations until a successful refresh.

The display projection, refresh pools and spending policy use the shared `UTXONetwork` registry instead of separate Bitcoin/Dogecoin display allowlists. Adding a future network requires explicit chain parameters and derivation support; its ledger inherits these pending-fund rules.

Pending-funds verification on 2026-10-11 (host only): 31 core tests passed, with four opt-in network tests skipped. The full database suite passed 83 tests with two network tests skipped; one additional dropped-outgoing-spend regression subsequently passed, for 84 database tests verified. At that point, the eight mempool integration tests iterated Bitcoin and Dogecoin and cover all HD branches, compressed/uncompressed imports, native/fiat display totals, pending descendants, reservations, confirmation/reorg, dropped/replaced transactions, cached reads, failure handling and mining maturity. The generic iOS Release build passed. No simulator, physical device, live mempool transaction, signing or broadcast was used for this change.

Send-path verification on 2026-10-13 (host only): all 18 `UTXOMempoolTests` passed. The added coverage uses the production discovery, ledger, planner, signer and journal on all four chains: only-pending funds, mixed confirmed/pending funds across every supported HD type and receive/change branch, then a second signed send spending the first transaction's pending change after reopening the database. Compressed and uncompressed private-key imports also sign pending inputs. These scenarios produced 24 signed transactions with durable reservations; dropped/replaced inputs and immature rewards remain excluded. Funding and mempool observations are deterministic fixtures, not public-network evidence. No simulator, physical device or network broadcast was used for this verification; production eligibility already allowed these outputs and required no behavior change.

Home, asset details and Receive use the shared engine for Bitcoin, Dogecoin, Litecoin and Bitcoin Cash. Coinbase USD quotes and local-currency conversion reuse the existing public market cache. Other chains remain at zero with no balance queries.

## Native linkage

BDK bundles SQLite. Statically mixing it with GRDB's system SQLite caused a host crash in `sqlite3_snapshot_get`. **Keep `OathBitcoin` a dynamic library and keep `_sqlite3*` symbols private to it.** The Xcode project explicitly embeds/code-signs `OathBitcoin.framework`; `project.yml` has `embed: true`. Host packages require macOS 15.5 to match BDK's binary deployment target. iOS remains 17.

## Verification

Host checks (no simulator/device):

```sh
swift test --package-path Packages/OathBitcoin --scratch-path /tmp/oath-bitcoin-build
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-bitcoin-database
swift test --package-path Packages/OathCloudBackup --scratch-path /tmp/oath-bitcoin-cloud-tests
```

Opt-in public-network checks use only published/deterministic public fixtures, never installed wallets:

```sh
OATH_BITCOIN_LIVE=1 swift test --package-path Packages/OathBitcoin --scratch-path /tmp/oath-bitcoin-build
OATH_BITCOIN_LIVE=1 swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-bitcoin-database --filter BitcoinLedgerTests/testLiveDiscoveryDatabaseCommitAndReopen
OATH_DOGECOIN_LIVE=1 swift test --package-path Packages/OathBitcoin --scratch-path /tmp/oath-bitcoin-build
OATH_DOGECOIN_LIVE=1 swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-bitcoin-database
OATH_LITECOIN_LIVE=1 swift test --package-path Packages/OathBitcoin --scratch-path /tmp/oath-bitcoin-build
OATH_LITECOIN_LIVE=1 swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-bitcoin-database
OATH_BITCOINCASH_LIVE=1 swift test --package-path Packages/OathBitcoin --scratch-path /tmp/oath-bitcoin-build --filter BitcoinCashTests
OATH_BITCOINCASH_LIVE=1 swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-bitcoin-database --filter BitcoinLedgerTests/testLiveBitcoinCashDiscoveryDatabaseReopen
python3 Tools/GenerateBitcoinCashVectors.py
python3 Tools/GenerateLitecoinVectors.py
python3 Tools/CheckMultiWallet.py
python3 Tools/CheckMultiWallet.py --envelope
```

Coverage includes published BIP44/49/84/86 addresses, seed and extended public/private key parity, compressed/uncompressed WIF, both gap boundaries, history on spent/change addresses, cancellation, malformed/error/empty responses, peer failover, raw transaction validation, 160-address live batches, complete live discovery/SQL reopen, reservation conflicts, coinbase maturity, stale/failure preservation, address switching and reset.

Bitcoin verification before Dogecoin integration, on 2026-10-11:

- Bitcoin package: 24 tests passed, including three live network tests; the additional incomplete/forged snapshot regression passed separately.
- Database: all 74 tests passed with the opt-in live scan enabled. The final regression run passed 73 local tests and skipped the opt-in network test.
- Encrypted cloud backup: 24 tests passed. Host vault/session checks passed, plus 39 envelope checks covering the new Bitcoin import format. These use synthetic credentials, fixture derivation and injected stores, not installed wallets or real Keychain data.
- Existing market-data and exchange-rate regression suites each passed ten local tests; their opt-in network tests were skipped.
- Generic iOS Debug and Release builds passed. The Release app contains and dynamically links the Bitcoin framework, and neither exports BDK's SQLite C symbols.
- Simulator UI, physical-device behavior, live iCloud, signing and transaction broadcasting were not tested.

Primary references: [BIP44](https://github.com/bitcoin/bips/blob/master/bip-0044.mediawiki), [BIP49](https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki), [BIP84](https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki), [BIP86](https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki), [Electrum protocol](https://electrumx.readthedocs.io/en/latest/protocol-methods.html), [BDK Swift 3.1.1](https://github.com/bitcoindevkit/bdk-swift/tree/3.1.1), [Apple library symbol visibility](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/DynamicLibraryDesignGuidelines.html).

Dogecoin references: [Core network parameters](https://github.com/dogecoin/dogecoin/blob/master/src/chainparams.cpp), [Core amount bounds](https://github.com/dogecoin/dogecoin/blob/master/src/amount.h), [Core WIF fixtures](https://github.com/dogecoin/dogecoin/blob/master/src/test/data/base58_keys_valid.json), [libdogecoin BIP32 tests](https://github.com/dogecoinfoundation/libdogecoin/blob/main/test/bip32_tests.c), [Qortal public peers](https://github.com/qortal/qortal/blob/master/src/main/java/org/qortal/crosschain/Dogecoin.java). The bundled Dogecoin fixture contains 80 receive/change addresses derived independently with Python cryptography/OpenSSL, plus 24 Core WIF cases. Only published or deterministic synthetic material is used in network tests.

Dogecoin integration verification on 2026-10-11:

- Core package: 29 passed; three opt-in Bitcoin network tests skipped. This includes all three live Dogecoin peers with 300-request batches, AuxPoW headers, known public-address history/raw transactions and failed-peer fallback.
- Database: 77 passed; one opt-in Bitcoin network test skipped. Live Dogecoin discovery/commit/reopen passed, along with cross-chain outpoint isolation, both HD branches, reservations, maturity, reset fencing and cached-snapshot preservation.
- Encrypted cloud backup: 25 XCTest tests and one Swift Testing test passed. Host vault/session/SQL: 403 checks passed, including 22 import/restore identity regressions; 50 separate envelope checks passed. The host adapter replaces iOS-only WalletCore profile derivation, Keychain and live iCloud with explicit fixtures/injected stores.
- Independent fixture generation is reproducible with `python3 Tools/GenerateDogecoinVectors.py` (requires Python cryptography). Its public Core fixture is pinned to a commit; production never runs this generator.
- The final generic iOS Release build passed after the import/restore identity fix. An earlier Dogecoin Debug build also passed. No simulator or device was launched.
- Simulator UI, physical-device behavior, live iCloud, signing and transaction broadcasting were not tested.


Litecoin integration verification on 2026-10-11:

- Core: 38 tests passed in the full run, with four opt-in Bitcoin/Dogecoin network tests skipped. One subsequent published-MWEB regression passed; the final eight-test Litecoin run passed, including both live peers. This gives 39 distinct verified core tests. The independent generator covers 320 address/script/hash vectors, 20 BIP32 scopes, all five private-prefix aliases, account public-key parity and 12 Litecoin Core WIF fixtures.
- Live checks exercised 160 public addresses per peer in bounded 300-request batches, valid empty results, historical use, hash-checked funding transactions, a published MWEB withdrawal, mainnet identity and a failed-server fallback. Public peer availability may change. No installed wallet was queried.
- Database: 87 tests passed, with two Bitcoin/Dogecoin network tests skipped; full live Litecoin discovery, atomic commit and reopen passed. The nine mempool tests were rerun after the six-confirmation peg-out rule and passed. They cover all three networks, incoming/pending descendants, outgoing deltas, dropped/replaced transactions, reorgs, reservations, cache failure/reopen and coinbase maturity. All four Litecoin Receive choices preserve the combined pool.
- Cloud backup: 26 XCTest tests and one Swift Testing test passed. Host vault/session checks passed 423 assertions, including 42 UTXO identity checks; a separate encrypted-envelope run passed 61 assertions. Production private-key descriptor code is tested on the host. Mnemonic/profile derivation, real Keychain and iCloud access remain explicit host adapters; these checks are not live iCloud validation.
- The final generic iOS Release build and compiled-resource localization checks (build 56) passed. No simulator, physical device, real-wallet scan, signing or broadcast was used. BIP38 decryption and confidential MWEB wallet derivation are not implemented; transparent MWEB peg-out receipts and their maturity are handled.

Bitcoin Cash integration verification on 2026-10-11:

- Core: 45 tests passed with the BCH live test enabled; five other-chain network tests were skipped. After adding explicit old-protocol rejection and request-parameter assertions, the final offline regression passed 44 tests and skipped six opt-in network tests. The seven BCH tests cover 80 independently derived receive/change address vectors, five extended-key scopes and public/private parity, 27 BCHN WIF fixtures, published CashAddr examples, and all 117 official valid/invalid CashTokens prefix fixtures.
- Live BCH checks passed against all three configured TLS peers, using 120 public-fixture addresses per peer, bounded 300-request batches, valid empty responses, known historical transactions, raw funding transaction validation and failed-peer fallback. No installed wallet or user secret was queried. Electrum remains a trusted history/unspent index, not an SPV consensus verifier.
- Database: 89 tests passed with live BCH discovery/commit/reopen enabled; three other-chain network tests were skipped. After routing the older paged-output API through the shared spendability checks, the final offline run passed 88 tests and skipped four network tests. Coverage includes BCH/BTC outpoint isolation, both gap boundaries, pending incoming/change, signed outgoing deltas, dropped/replaced transactions, reorgs, reservations, maturity, cache reopen and failure preservation. Token-bearing BCH is included in balances but cannot enter either ordinary spending API or a send reservation.
- Cloud backup: 27 XCTest tests and one Swift Testing test passed. Host vault/session/SQL checks passed 437 assertions, including 56 UTXO import/restore identity checks; the separate encrypted-envelope run passed 72 assertions. Production private-key descriptor code is exercised; mnemonic/profile derivation, Keychain and iCloud access use explicit host fixtures/adapters. These checks do not validate live iCloud or the physical device's Keychain.
- The final generic iOS Release build passed, followed by 75,353 compiled-localization, language-registry, search, format, font and preference checks for build 56. The build emitted the existing App Intents metadata-extraction warning because the target has no AppIntents dependency; no compiler errors occurred.
- No simulator or physical device was launched. UI runtime, live iCloud, signing and broadcast were not tested. Send remains deferred. BIP38 decryption, legacy Electron Cash seed formats, arbitrary legacy-path discovery, multisig and CashTokens transfer UI are not implemented.

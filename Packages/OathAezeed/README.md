# Local aezeed recovery

Current release: [4.1.15 (99) verification record](../../releases/4.1.15.md). Historical checks below describe their original scope; they are not an independent audit of this release.


This package decodes LND aezeed version 0 envelopes with internal seed versions
0 and 1. It uses the pinned LND v0.19.3-beta implementation through a narrow C
bridge, including production scrypt parameters and AEZ authentication. It does
not reinterpret the 24 words as BIP-39. Password UTF-8 bytes are preserved,
including whitespace, Unicode and embedded NULs; BIP-39 normalization is not
applied. An omitted password uses LND's default.

The app imports these wallets as Bitcoin-only, with recovery material stored
inside its authenticated local vault (format 25). Recovery drafts stay local
because incomplete input cannot identify the mnemonic format. Aezeed is excluded
from iCloud backup export in 4.1.5. Preserve the original words and required
passphrase. This public release has no operator wallet or recovery-input upload path.

Bitcoin account 0 discovery covers external and change branches for purposes 44,
49, 84 and 86. Purpose 49 uses LND/btcwallet's BIP49Plus policy: nested SegWit
receiving addresses and native SegWit change. Standard BIP-39 policy is unchanged.
The existing bounded gap discovery applies. Arbitrary custom LND accounts,
separately imported keys and Lightning channel recovery are not implemented by
this import. Channel backups must be restored in a Lightning-compatible wallet.

## Build and reference fixtures

`Tools/AezeedBridge/build.sh` rebuilds the checked-in static XCFramework for
arm64 iOS, arm64 iOS Simulator and arm64 macOS. It requires Xcode and Go; this
build was made with Go 1.26.5 and Xcode 27.0 (27A266a). `go.mod` and `go.sum` pin upstream dependencies.
[BuildProvenance.json](BuildProvenance.json) records the rebuilt archive and input
hashes. Two builds from separate paths matched all framework files. This does not
establish equivalence to historical App Store binaries.
The bridge exposes no network, filesystem or logging API and limits concurrent
KDF work to one invocation. Mutable bridge buffers are cleared after use; this
is not a guarantee that Swift/Go runtime copies are eliminated from memory.

Reference commands, from `Tools/AezeedBridge`:

```sh
go run ./cmd/seedvectors
go run ./cmd/vectors
```

Only fixed, publicly documented test entropy is used by these generators. Never
fund these fixtures on a public network. LND's own unit tests change scrypt to
N=16; their mnemonic strings are not production-compatible. Our generated
fixtures use the unmodified production implementation (N=32768).

## Validation

From the repository root:

```sh
swift test --package-path Packages/OathAezeed --scratch-path /tmp/oath-aezeed-host
swift test --package-path Packages/OathBitcoin --scratch-path /tmp/oath-aezeed-bitcoin --filter 'AezeedBitcoinTests|BitcoinKeysTests|BitcoinPrivateKeysTests|DiscoveryTests'
OATH_VALIDATION_SCRATCH=/tmp/oath-aezeed-vault-native python3 Tools/CheckMultiWallet.py --aezeed
python3 Tools/CheckScanner.py
```

The vault harness uses production aezeed import, derivation, encrypted storage,
SQLite and recovery code. It substitutes in-memory storage/biometrics and
no-network services. Its BIP-39 profile adapter is a fixture; BIP-39 cryptographic
regressions are checked separately in the Bitcoin package.

For the opt-in funded Bitcoin Core check, create a disposable regtest node at
`/tmp/oath-aezeed-regtest`, RPC port 19643, with wallet `aezeed-test`, txindex and
fallback fees enabled. Supply `OATH_AEZEED_REGTEST_DIR` when running the Bitcoin
tests. The test funds eight real scripts, checks their outputs, signs an
eight-input transfer, submits it to Core, mines it and checks spent outputs and
change. Discovery consumes fixtures populated from those Core outputs; this is
not an end-to-end Electrum or public-testnet synchronization test.

Upstream references:
- https://github.com/lightningnetwork/lnd/blob/v0.19.3-beta/aezeed/cipherseed.go
- https://github.com/btcsuite/btcwallet/blob/master/waddrmgr/scoped_manager.go

Bundled licenses are in `THIRD_PARTY_NOTICES.txt` and the app's notices resource.

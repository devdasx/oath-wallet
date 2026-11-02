# Public build configuration

Version: 5.0.0 (102). Scheme: `OathAtmosphere`. Product: `Oath Wallet`.

Run `sh Tools/PreparePublicBuild.sh` before the first build. It creates an empty
`OathApp/Private/TokenRPC.plist` only when one does not exist. This directory is
ignored. Existing local values are never overwritten or printed.

Provider-backed functionality reads these optional string keys from that file:

- `AnkrAPIKey`: supported RPC and indexed balance/history requests.
- `AlchemyAPIKey`: supported provider queries.
- `AlchemyUTXONetworks`: comma-separated Bitcoin-family network IDs enabled in your Alchemy account. The default is empty; a general API key does not enable these capabilities.
- `AptosIndexerAPIKey`: Aptos indexed queries.
- `BlockscoutAPIKey`: supported explorer indexing.
- `EnvioAPIKey`: supported indexed EVM queries.
- `WalletConnectProjectID`: WalletConnect relay configuration.

Use your own provider accounts. Never commit the populated file or include it in a
source archive. Without configuration, compilation and local wallet operations
remain available; affected remote features report unavailability. Credentials
bundled in any client app are extractable and must have provider-side restrictions.

Choose your own Apple team for device builds. The stable bundle identifier,
Keychain access names, and iCloud container names preserve the application's
upgrade identities; changing them affects access to previously stored data.

## Exclusions and local behavior

The app uses encrypted local vault storage and on-device signing. Diagnostics remain local.

The diagnostics package still filters secrets and untrusted error text before
writing its bounded local outbox. Without a transport, flush does not upload,
acknowledge, erase, or schedule retries for pending events.

Optional iCloud backups use the app's explicit encrypted-backup flow. Review its
implementation and configure Apple entitlements before enabling it in your build.

## Test material

Tests include intentionally public synthetic keys, standard mnemonic vectors,
on-chain public addresses, ABI bytes, and public SDK fixtures. These are not user
wallets or deployment credentials and must never receive funds. XRPL vectors are
generated from the explicitly fixed synthetic entropy in
`Tools/GenerateXrplSendVectors.cjs`. Other vector generators document their fixture
inputs alongside the tests. Vendor test fixtures remain covered by their license.

Reviewed scanner matches are recorded with exact fingerprints and file hashes in
`.gitleaksignore` and `Tools/PublicFixtureReview.json`. The validator rejects a
changed exception file until it is reviewed again; it does not disable rules for a
whole folder. These checks supplement review and do not prove absence of every
possible secret or vulnerability.

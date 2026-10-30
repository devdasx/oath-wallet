# XRP Ledger sending

## Implemented scope

Oath sends XRP, classic issued currencies (currency + issuer), and public MPT
balances through the existing recipient, amount, review, authentication, success,
activity, and recovery flows. Wallets use the app's existing secp256k1 XRP keys.
Mainnet uses the configured ANKR XRP RPC first and `xrplcluster.com` for provider
failure fallback. Testnet tests use the official public Testnet endpoint.

Preparation reads fees and ledger state concurrently, then reads account/token
state concurrently against one validated ledger. It protects the current account
reserve, validates destination tags (including zero), includes issuer transfer
charges, and simulates the exact Payment before presenting a quote. Max preserves
the XRP reserve and network fee; token Max also accounts for transfer charges.
Issued amounts retain their protocol precision rather than using floating-point
balances. Fiat conversion is optional and follows the existing no-price fallback.

The app constructs and signs Payment bytes locally. The fee, destination, tag,
amount, spending limit, sequence, and final valid ledger are frozen for review.
Signing requires the existing biometric/passcode authorization and active-wallet
checks. Private keys never go to the RPC provider. An expired quote must be
prepared again before signing.

The signed transaction is durably stored before broadcast. Duplicate imports of
the same address share a reservation. Retries and relaunch recovery reuse exactly
the same signed bytes. Preliminary submission success is not confirmation: only
validated ledger evidence with the exact delivered amount settles successfully.
An ambiguous timeout stays pending. Expiry requires a complete search of the
transaction's valid ledger range. Validated failures retain their consumed XRP
fee, including unfamiliar future `tec` results, without retaining untrusted error
text. Shared OathDiagnostics handles filtered failures.

Recipients must already meet issuer trust-line/MPT authorization requirements.
Simulation rejects restricted, frozen, unfunded, or otherwise invalid payments.
This feature does not create trust lines, authorize tokens, issue tokens, change
account settings, send NFTs, decrypt confidential MPT balances, or sign for
multisignature/disabled-master accounts. These are separate operations, not
silently added to a transfer.

## Verification — 2026-10-14

The production Swift quote, serializer, signer, submitter, and confirmation client
executed real public **Testnet** transactions. Three temporary faucet-funded
accounts and test-only issued/MPT assets were used; no application wallet or
mainnet funds were used.

| Transfer | Validated Testnet transaction hash |
| --- | --- |
| XRP | `0A272CD26D5D5B86749C38C0D7D7097513AF4DED51E2EAE058AC39EF27D208A4` |
| Issued token | `3CB6F730CB1F5E7356EF9FBDD272EDF3119400D7BD70ACF07B99BD1805D6456A` |
| MPT token | `988457440D5BB978241CA1F2AE233EB15CA974BC22A8BE12EED92727951148E6` |
| XRP Max | `B6D263287EC990615F0898E0C33F4E5A96E31E666C00E471E534E67603B01603` |
| Issued token Max | `96EBF4B3A98808FF867F474D838F4863B255BADD8A0BBC02109B1D5017286A85` |
| MPT token Max | `666E24B7F21A55A28C44E0F102A0DF410165F1DADBBC79320F9D46780F1E41F0` |

Checks verified exact delivery, source debit, 1% token transfer fees, XRP reserve
preservation, zero destination tags, and retrying a signed transaction without a
second payment. Live negative checks rejected a missing required tag, an
underfunded new recipient, and an issued-token recipient without a trust line.
A separate temporary account was funded and used for the native Max check.

Local signing bytes, deterministic signatures, public addresses, and transaction
hashes match independently generated `xrpl.js` 5.3.0 vectors for all three asset
types. The vector key is a deterministic **unfunded test-only** key, unrelated to
the live fixture or user wallets.

Additional host checks cover wrong networks, bounded expiry, ambiguous broadcast,
unexpected delivered amounts, provider-error privacy, durable journal reopening,
duplicate-wallet reservations, signed-payload tampering, and terminal outcomes.
Nine authorization checks exercise the production vault, PIN, and imported-key
signer, with a synthetic biometric store. Amount/recipient checks pass 232 cases.
Bitcoin Cash signing regressions, Sui journal regressions, OathDiagnostics host
tests, the diagnostics coverage guard, and a generic iOS build also pass.

No simulator or physical-device runtime/visual tests were run. OS biometric UI
and mnemonic XRP derivation on a device are not established by the host harness.
No mainnet transaction was broadcast. These results verify the cases above, not
every possible issuer policy or future provider response.

## Repeatable checks

### Mainnet refresh-loop regression — 2026-10-14

Live ANKR `server_info` omitted `info.network_id`, while the configured fallback
returned numeric mainnet ID `0`. The sender previously converted both a missing
ID and an explicit mismatch into `wrongNetwork`. That error intentionally stops
failover, leaving the review without a quote and making Refresh repeat the same
failure. Testnet fixtures always included the ID, so they missed this case.

Missing or malformed identity now follows the existing provider-protocol failure
path, allowing the fallback to prepare a new, fully validated quote. It does not
assume a network from an absent field. Explicit network mismatches still stop the
operation. The shared state check also fixes reconciliation and exact-byte retry.
Existing shared diagnostics record the protocol failure at the failover boundary;
no additional response content or credentials are logged.

Three new deterministic regression tests cover omission on ANKR, successful
fallback quote/reconciliation, malformed identity without a usable fallback, and
explicit mismatch rejection. The omission test failed with `wrongNetwork` before
the source fix and passed afterward. The XRP host suite passed 22 tests (4 opt-in
live tests skipped); all 5 journal tests passed. Diagnostics passed 37 tests
(2 opt-in tests skipped), the diagnostics coverage guard passed, and the generic
iOS build succeeded.

A separate read-only mainnet test ran the production quote client for normal XRP
and Max through both the configured ANKR/fallback path and the fallback directly.
All four simulations passed with a fee of 12 drops; measured quote times were
1.93s / 2.92s and 0.59s / 0.54s respectively. These are individual observations,
not a latency guarantee. The test transport rejects every RPC outside the read/
simulation allowlist. No signing or broadcast occurred, and no simulator or
physical device was used for this fix.

```sh
python3 Tools/CheckXrplLive.py --run --send-quote
```

From the repository root:

```sh
swift test --package-path Packages/OathAnkr --filter Xrpl
swift test --package-path Packages/OathDatabase --filter XrplSendJournalTests
python3 Tools/CheckMultiWallet.py --xrpl-send
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Live tests are opt-in. Install `xrpl@5.3.0` in a temporary reference directory and
set `NODE_PATH` to its `node_modules`. `Tools/PrepareXrplTestnetFixture.cjs` creates
three separate Testnet accounts, trust lines, and an MPT issuance. It writes keys
only to a private `/tmp/` fixture with mode 0600. The fixture preparer was
consolidated from the setup operations used for this verification; a fresh run of
the consolidated script has not separately been verified. Never use real wallet
keys or check the fixture into source control.

```sh
node Tools/PrepareXrplTestnetFixture.cjs /tmp/oath-xrpl-testnet-fixture.json
OATH_XRPL_TESTNET_FIXTURE=/tmp/oath-xrpl-testnet-fixture.json \
  swift test --package-path Packages/OathAnkr --filter XrplSendTests.testLive
```

Fixture setup depends on the public faucet. If a setup submission times out,
inspect its outcome before repeating setup. Send tests intentionally broadcast
small Testnet payments and return recipient token balances in their Max cases.

## References

- [XRPL Payment](https://xrpl.org/docs/references/protocol/transactions/types/payment)
- [XRPL transaction cost](https://xrpl.org/docs/concepts/transactions/transaction-cost)
- [XRPL simulate](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/transaction-methods/simulate)
- [Reliable transaction submission](https://xrpl.org/docs/concepts/transactions/reliable-transaction-submission)
- [Sending an MPT](https://xrpl.org/docs/tutorials/payments/send-an-mpt)
- [Issuer transfer rates](https://xrpl.org/docs/references/protocol/transactions/types/accountset)
- [Official JavaScript SDK](https://github.com/XRPLF/xrpl.js)

## Explicit recovery of the final 1 XRP

Max can offer a native confirmation only for a native XRP balance of exactly
1,000,000 drops. Live state must also show that this equals the base reserve.
Approval selects an AccountDelete intent, never a Payment that ignores reserves.
The review uses a distinct Close & Send action, discloses account deactivation,
and shows the recovered balance and live owner-reserve closing fee. English and
Arabic copy explain that the recipient must be activated and that failed execution
can consume the closing fee. The app does not delete the wallet or its keys.

This narrowly scoped flow requires no owned or linked ledger objects, no sponsor
obligations, eligible sequence/NFT age, an enabled master key, a funded destination
and any required tag. It fails closed on paginated/unknown object inventories.
A conservative extra ledger margin covers the documented sequence-age boundary.
Quotes simulate exact AccountDelete JSON. Eligibility is checked again after
authentication and immediately before submission, which uses fail_hard. A live
fee above half the final reserve is not offered. Existing Payment limits stay intact.

AccountDelete has no Amount field: it sweeps the remaining balance, including XRP
received before execution. Confirmation proves source deletion and destination
credit from metadata, and persists the actual credit if it differs from the quote.
Pending, failed and expired transactions use the existing durable journal and
reconciliation. A balance/recipient/tag/amount/wallet change requires fresh consent.

Expected closure eligibility failures and cancellation are validation, not app
failures. Transport, malformed provider replies and unexpected execution failures
use the shared privacy-filtered OathDiagnostics boundary. Host tests cover signing
against independent xrpl.js bytes, malformed intents, stale eligibility, obligations,
recipient activation/tags, pinned ledgers, simulation, fail_hard, pending/final/failed
results, persistence and consent invalidation. These are not live account deletions.

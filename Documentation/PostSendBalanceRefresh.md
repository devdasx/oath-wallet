# Balance refresh after sending

Bitcoin, Bitcoin Cash, Litecoin and Dogecoin use a shared, durable post-send
balance refresh. It belongs to the send service and unlocked application session,
not the send sheet. Dismissing the sheet does not discard the refresh.

## Lifecycle

1. `OathDatabase.transitionSend` records a refresh intent atomically when a send
   enters `broadcast` or `confirmed`. Recording it before submission also covers
   an interrupted request whose acceptance was not returned to the app.
2. A successful broadcast acknowledgement immediately requests a refresh for the
   original wallet and network. Reconciliation of a previously submitted send
   uses the same entry point.
3. The adapter refreshes balances for all HD accounts of that wallet on that
   network, including receive and change branches and supported address types.
   It does not request the unrelated chains or full transaction-history service.
   The normal database observation updates displayed balances.
4. HTTP/RPC success alone does not complete the intent. The committed scan must
   contain the exact submitted transaction on the contributing accounts, consume
   its inputs, and have no active/failed scan. This allows self-transfers and
   send-all while rejecting a successful but stale pre-send response.
5. The worker attempts immediately, then waits 1, 2, 4, 8 and 16 seconds between
   subsequent attempts. Original failures go through shared diagnostics. Indexer
   propagation and normal cancellation are not logged as app failures.
6. After six attempts, unfinished work stays in SQLite. Foreground activation,
   unlock or reopening the app resumes it. A new send can also request another
   burst. Network outages and delayed indexing cannot guarantee immediate results.

Locking or changing wallets pauses/cancels active work. Unlocking or completing
the wallet switch resumes pending work for its original wallet/network rather
than redirecting it to the selected wallet. App reset removes the worker and
cascades its intents with the send journal. Soft-deleted wallets are excluded.
Duplicate acknowledgements are idempotent. The queue pages at most 64 targets
into memory, runs at most four targets concurrently, and coalesces requests for
the same wallet/network. Each batch reads at most 100 sends.

This worker never signs, broadcasts, modifies send status, or releases reserved
inputs. A balance refresh failure cannot turn a submitted payment into a failed
payment or initiate another payment.

## Adding a future chain

Every chain using the shared journal automatically gets the durable intent. Its
send adapter must call `OathPostSendBalanceRefresh.shared.submitted` after an
accepted broadcast/reconciliation and add a branch to the shared refresh adapter.
The adapter must:

- Refresh the supplied wallet/network, including relevant native/token balances.
- Commit authoritative data through the normal database/observation path.
- Return only send IDs whose transaction effects are present in that committed
  snapshot; a successful RPC request or arbitrary balance change is insufficient.
- Preserve cancellation and use shared diagnostics without logging wallet IDs,
  addresses, signed payloads, secrets or request/response bodies.
- Add chain-specific observation tests using the shared worker tests as a model.

Unsupported adapters fail explicitly into diagnostics and retain pending work;
they are never silently acknowledged. `future-chain` in the host suite tests the
generic routing contract, not an implementation of an additional real network.

## Verification

`PostSendBalanceRefreshTests.swift` exercises journal migration, four-chain and
future-adapter routing, retries after transport errors and stale responses,
restart recovery, duplicate requests, a second send during refresh, cancellation
with late callbacks, wallet/network isolation, deletion/reset and queue paging
with bounded concurrency.

`UTXOMempoolTests.testPostSendWorkerRefreshesRealSignedBalancesAcrossAllFourChains`
uses the production transaction planners/signers, all supported receive/change
branches, discovery, scan commits, balance queries and observation check. For
each of the four chains it tests an external send, self-transfer and send-all,
first returning stale data and then a snapshot containing the signed transaction.

These are host tests with public deterministic fixtures and controlled provider
responses. They do not broadcast a payment or prove live-provider propagation
timing, on-device rendering or background execution while iOS suspends the app.

# Bitcoin-family review preparation

Applies to Bitcoin, Bitcoin Cash, Litecoin and Dogecoin.

- Amount Continue freezes the reviewed amount/options and starts preparation in
  the same action. `OathSendFlow` owns the send model across navigation. Review
  appearance and biometric capability detection do not start or restart it.
- Fee lookup starts before database/account reads. Account scans run concurrently;
  change-address preparation overlaps loading/validating the spendable coin pool.
  These operations run through background actors, outside the main UI actor.
- Quotes can reuse a complete, successful account scan for at most 30 seconds.
  Missing, future-dated, failed and in-progress snapshots cannot be reused. A
  reuse does not renew the timestamp. Explicit Refresh transfer forces a scan.
  Foreground sync and quote preparation still join one scan per account.
- Electrum probes start together. After the first verified response, peers have
  250 ms to supply a newer tip; if all respond earlier there is no delay. Without
  a healthy response the existing 5-second probe deadline remains. Discovery
  races isolated peers at the highest observed tip, retains start/end consistency
  checks and never falls back below a higher tip already observed in that run.
  Unanswered peers do not supply evidence of their chain height.
- Leaving review, dismissing the flow or locking invalidates its result. Shared
  read-only scans can finish for other callers; cancelled UI requests cannot
  publish a late quote.
- Signing still requires Confirm & Send and authentication. Input reservations,
  plan/funding validation, durable signed-byte journaling and broadcast ordering
  are unchanged. Signing and broadcasting are dependent operations, not tasks
  that can safely run alongside unfinished fee/amount preparation.

Errors retain the shared diagnostics boundary and operation context. Cache misses
and cancellation of losing probes are expected control flow, not new app errors.

## Validation

- `ElectrumSnapshotTests.testStalledProbeDoesNotHoldHealthyDiscoveryForEveryChain`
  reproduced the previous wait on all four chains (~2 seconds for a deliberately
  stalled fixture). With the fix the same fixture completes in ~0.26 seconds.
- The snapshot suite covers higher observed tips, block changes, failed peers,
  TLS/network rejection and cancellation.
- `UTXOMempoolTests.testReviewReusesOnlyRecentlyVerifiedCompleteSnapshotsForEveryChain`
  covers the reuse window, account isolation, future dates, unchanged timestamps,
  failed scans and scans in progress. Existing reservation, funding, signing and
  maturity tests remain in that suite.
- The opt-in `ElectrumSnapshotTests.testLiveFeesAndFundingDiscoveryForAllChains`
  uses public deterministic test descriptors and default public fee providers.
  It neither accesses an installed wallet nor signs/broadcasts. Its latency does
  not establish physical-device performance or the configured Alchemy latency.

Run the OathDiagnostics host tests, diagnostics coverage guard and a generic iOS
build with these changes. Simulator/device validation is separate.

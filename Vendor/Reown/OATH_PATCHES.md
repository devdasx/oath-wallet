# Pinned Reown integration fixes

This directory contains the upstream Reown Swift SDK **2.4.0**, revision
`1286a56685266804f3ceae93e394f45eb4473dfb`, including its original package,
sources, tests and license. `project.yml` uses this local package so the fix is
reproducible; no build step mutates an Xcode or SwiftPM checkout.

The original transport patch (2026-10-15):

- `Sources/WalletConnectRelay/SocketConnectionHandler/WebSocket.swift` adds the
  optional `WebSocketErrorReporting` transport capability.
- `Sources/WalletConnectRelay/Dispatching.swift` uses that capability to return
  a real write failure to its existing callback/async callers. Transports that
  only support the upstream success callback retain their original behavior.

The upstream success-only write completion leaves `protectedSend` suspended
when the native connection is lost before/during a write. Relay ACK timeouts are
started **after** that await, so they cannot release it. Reporting success on
failure is unsafe: session approval also uses this dispatcher.

Oath's native URLSession transport implements the new capability, terminates
pending writes on disconnect, limits pending writes to 64, and closes a socket
whose write exceeds 20 seconds. Its lock removes each completion once; late
callbacks from an old task cannot finish a newer connection. Transport failures
continue through shared OathDiagnostics. Intentional close is cancellation.
No relay replies are synthesized and no payloads are logged or automatically
replayed by this patch.

Validation: `python3 Tools/CheckWalletConnectTransport.py --live` runs the exact
native socket and the SDK dispatcher/status-provider source on the host. It
covers disconnect between connection-check and write, async error propagation,
handshake teardown, timeout/capacity/privacy, close/reconnect, and authenticated
publication/delivery on the real relay using disposable fixture identities.
The harness stubs unrelated URL construction, logging and network availability;
it does not claim full app or automatic-reconnect-manager coverage.

The upstream `LICENSE` and app's ThirdPartyNotices remain included. This patch
does not change the SDK version, relay endpoints, signing or key storage.

## Xcode warning and connection-wait repair — 2026-10-15

The package remains pinned to the revision above. Additional local changes:

- InitEvent/MessageEvent explicitly decode payloads while keeping fixed event
  discriminators. AuthRequestParams and Session retain their original serialized
  `methods` and `pairingTopic` keys behind deprecated compatibility accessors.
- CryptoKit wrapper equality compares wrapper key bytes without adding imported
  Equatable conformances. VerifyContextFactory is a stateless Sendable value.
- HTTPNetworkClient decodes outside actor isolation and uses cancellable native
  URLSession async calls through DiagnosticHTTP. Failures retain the shared
  filtering/outbox, HTTP status and operation correlation; no body/path is logged.
- NetworkingInteractor encodes caller-owned values before suspension. Immutable
  JSON/envelope metadata reaches QueuedSerializer's dedicated serial executor;
  keychain IPC stays off cooperative executor threads. Serializer retains both
  wire-format encoding policies and adds a JSON overload.
- Automatic/manual handlers synchronize state through reentrant queue access.
  SocketConnectionWaiter installs observation before starting, completes exactly
  once, bounds waits by the existing timeout/retry limit, and releases cancelled
  callers promptly. Concurrent callers wait instead of returning false success.
  Its small lock-protected callback bridge is Sendable; handlers are not declared
  Sendable. Cancellation does not disconnect other users of the shared socket.
- Session responders share their delayed main-actor next-request emission.
  Link dispatch captures only the URL/continuation in main-queue callbacks.
- Previously abandoned throwing tasks in relay, pairing, auth and session engines
  now catch and report original errors through OathDiagnostics with fresh operation
  IDs. Normal cancellation is excluded by shared filtering. Existing thrown
  failures continue to callers; no success ACKs are fabricated.
- Unused local bindings, an unreachable catch and `private(set)` syntax are fixed.

The local manifest adds OathDiagnostics to HTTPClient, Relay, Pairing and Sign;
its deployment minimums match that local dependency (iOS/tvOS 17, macOS 14).
The app already targets iOS 17. Upstream version, endpoints and crypto algorithms
are unchanged. No global warning suppression is enabled.

Validation: `Tools/CheckWalletConnectSDK.py` builds production modules in a host
harness and exercises saved JSON compatibility, key equality/signature verification,
concurrent verification, all three encrypted/link envelope variants, HTTP decode/
status/cancellation/privacy, actual pairing background failure reporting and
connection wait races. Schemas use the production
outer Session/Namespace declarations with unrelated proposal-engine types omitted;
only the TTL constants are stubbed. Socket/key-store fixtures do not access user
wallets or the real keychain. The complete app clean generic iOS build covers the
full SDK integration. The separate transport harness's live relay check proves
ACK/delivery/reconnect, not a dApp approval UI or on-chain transfer.

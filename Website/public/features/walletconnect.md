# Connect to dApps with WalletConnect

Connect Oath to a compatible dApp using its WalletConnect QR code or app link. Choose the wallet and networks you intend to share, then review each later request in Oath.

[Get Oath for iOS](https://apps.apple.com/app/id6780187283) · [Read the detailed guide](https://help.oathwallet.org/articles/connect-dapp)

![Oath WalletConnect proposal showing the website, selected wallet, networks and connection permissions](https://oathwallet.org/help/assets/guide-wc-connect.webp)

Oath 4.0.3 · Actual app screen showing an offline sample proposal. It does not establish a live connection, endorsement or completed transaction.

## Check the website

Compare the full website address and read verification warnings. A familiar name or icon can be copied.

## Choose the connection

Review the proposed accounts, networks and methods before approving the session.

## Approve requests separately

A connection lets the dApp request supported actions. It does not approve every future signature or transfer.

## Compatibility is specific to the request.

A network in your portfolio does not guarantee every dApp or signing method works. The released app checks the requested network and method before proceeding.

### Compatible EVM requests

Supported mainnet EVM connections allow the signing and transaction requests implemented in Oath. Arc connections are not supported in this release.

[Ethereum](https://oathwallet.org/networks/ethereum) · [Base](https://oathwallet.org/networks/base) · [Arbitrum](https://oathwallet.org/networks/arbitrum) · [Polygon](https://oathwallet.org/networks/polygon)

### Other supported networks

Oath supports compatible requests for Bitcoin, Solana, THORChain, XRP Ledger, Stellar, NEAR, Sui, Polkadot, TRON and Gram/TON. Available actions differ by network and dApp.

[Bitcoin](https://oathwallet.org/networks/bitcoin) · [Solana](https://oathwallet.org/networks/solana) · [THORChain](https://oathwallet.org/networks/thorchain) · [NEAR Protocol](https://oathwallet.org/networks/near) · [Polkadot](https://oathwallet.org/networks/polkadot) · [Gram](https://oathwallet.org/networks/gram)

### dApp and protocol limits

The dApp must offer a compatible mobile WalletConnect connection. WalletConnect is separate from TON Connect and browser-extension-only connections. Unsupported required methods or networks can prevent a session.

## Connect with the details in view.

1. **Start from the dApp.** Open the intended website and choose WalletConnect. On another screen, scan the QR with Oath; on the same device, use the Oath link offered by the dApp.
2. **Review the proposal.** Unlock Oath if asked. Check the website, wallet, networks and requested permissions before connecting. Reject a proposal you cannot explain.
3. **Review each request.** Return to the dApp, then inspect each signature or transaction in Oath. Check the network, destination, amount and fee where applicable.

## Manage the session when you are finished.

Find connections in Settings → WalletConnect or Permissions → Connected DApps. Disconnect an unwanted session, then check token approvals separately if you also want to remove on-chain access.

[Read the disconnect guide](https://help.oathwallet.org/articles/dapp-disconnect)

## Questions

### Does connecting share my recovery phrase?

No. A connection shares the approved public accounts and permits supported requests. Never enter recovery words or private keys into a dApp, and never publish a WalletConnect pairing QR or URI.

### Why can a connection be rejected?

The proposal may be expired, or require a network, method or account the installed app cannot support. Read the message in Oath and start a fresh connection from the intended dApp if needed.

### Is connecting the same as approving a token allowance?

No. Session approval and on-chain token access are separate. Review each request, and use the token-access tools to inspect supported allowances.

### Can every Oath network use every dApp?

No. Compatibility depends on the network, wallet account and action requested by the dApp. Follow the relevant network guide and the options shown in your installed app.

## Detailed guides

- [Connect your wallet](https://help.oathwallet.org/articles/connect-dapp)
- [Disconnect a session](https://help.oathwallet.org/articles/dapp-disconnect)
- [Review token access separately](https://help.oathwallet.org/articles/revoke-token-access)




## When a dApp will not connect

### The dApp shows only browser-extension wallets. Can Oath connect?

The dApp needs a compatible WalletConnect or mobile app-link flow. Oath cannot make an extension-only connection option work. Check the dApp’s supported mobile wallets and exact network.

### Does connecting permit every future transaction?

A session and a signing request have separate reviews. Read the website, account, network and requested action each time. Disconnect a session you no longer use and review token approvals separately.

- [Check Solana dApp and test-network scope](https://help.oathwallet.org/articles/walletconnect-solana)
- [Review token approvals separately](https://oathwallet.org/features/revoke-token-approvals)
- [Find network-specific connection guidance](https://oathwallet.org/networks)
- [Find the fee asset for your network](https://oathwallet.org/networks/fees)

Product guidance for Oath 5.0.2 (104); updated 2026-11-06. [How we review guides](https://oathwallet.org/about#editorial).


## Release and source details

Feature scope reviewed for Oath 5.0.2 (104) on 2026-11-06. Screens show Oath 4.0.3; appearance can differ in newer versions.

[Release availability record](https://github.com/OathWallet/oath-wallet/blob/main/releases/5.0.2-distribution.json)

- [OathWalletConnectPolicy.swift](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/OathAtmosphere/Scanner/OathWalletConnectPolicy.swift)
- [OathWalletConnectConnections.swift](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/OathAtmosphere/Scanner/OathWalletConnectConnections.swift)

Source review and sample screens do not establish a completed live transaction or backup.

## More Oath features

- [Check and revoke token approvals](https://oathwallet.org/features/revoke-token-approvals)
- [Encrypted iCloud wallet backup](https://oathwallet.org/features/icloud-wallet-backup)

[All features](https://oathwallet.org/features)

# Solana wallet: send and receive SOL

Keep SOL and supported Solana tokens together, with receiving, sending and compatible dApp connections.

## Receive Solana

1. Open Oath, select your wallet and choose Solana in Receive.
2. Copy the receiving address or show its QR code. Confirm the exact network with the sender.
3. Use the Solana address in Receive. Match a token by its mint and network, not its symbol alone.
4. After the sender broadcasts the transfer, follow its status in Oath. Network confirmation can take time.

## Send SOL

1. Open Send and select the asset on Solana. Paste the recipient’s address or scan their QR.
2. Keep SOL for fees and any required token-account creation. Review the fee and remaining balance before confirming.
3. Enter the amount and any required memo or tag. Compare the complete destination with the recipient’s instructions.
4. Review the asset, network, amount and fee, then confirm in Oath. Follow the transaction status after broadcast.

## dApp connections

Connect to compatible Solana dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app. A website that only detects browser extensions may not offer a compatible mobile connection.

1. Open a trusted dApp and choose Oath if it is listed, or choose WalletConnect.
2. On desktop, scan the connection QR with Oath. On iPhone or iPad, use a compatible app link or the connection option offered by the dApp.
3. Review the website, selected wallet, Solana network and requested permissions before approving.
4. Review each signing request separately. Disconnect the session from Oath when you are finished.

## Questions

### How do I receive Solana in Oath?

Open Oath, select your wallet and choose Solana in Receive. Copy the receiving address or show its QR code. Confirm the exact network with the sender. Use the Solana address in Receive. Match a token by its mint and network, not its symbol alone.

### What pays the Solana transaction fee?

SOL is the native fee asset for this network account. Keep SOL for fees and any required token-account creation. Review the fee and remaining balance before confirming.

### Can I connect Solana dApps?

Connect to compatible Solana dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app. A website that only detects browser extensions may not offer a compatible mobile connection.

### Can I send to the same address on another network?

Only send using the network the recipient explicitly supports. A matching address or ticker does not bridge assets or make different chains interchangeable.

Features depend on the app version, network, wallet type and the service you connect to. Check the available actions in your installed app before transferring.

[Network catalog](https://github.com/OathWallet/oath-wallet/blob/1e99ef95c504c3ac5e7788f507096c518cfece5c/OathAtmosphere/Import/OathImportCatalog.swift) · Updated 2026-10-31. Source review is not confirmation of App Store availability.

[Get Oath for iPhone and iPad](https://apps.apple.com/app/id6780187283) · [All networks](https://oathwallet.org/networks)


## When a transfer needs a closer look

### Why can the first token transfer cost more?

A transfer can require a recipient token account to be created as well as a transaction fee. Review the SOL requirements in Oath; there is no single fixed amount that fits every token and recipient.

### Why is my token balance available but Send cannot continue?

A token balance and the network fee balance are separate. Check that SOL is available on Solana, then read Oath’s estimate and any account requirements. A balance on another network cannot pay this transaction’s fee.

### The sender says it is complete. Where is my transfer?

Ask for the public transaction ID and the exact network. Check the destination and token identifier in that network’s explorer. A withdrawal request is not the same as a confirmed on-chain transfer. If the explorer confirms the correct transfer, refresh the matching account in Oath.

### What if I selected the wrong network?

Stop and check the original transaction before sending again. A matching address is not proof of recovery. Contact the receiving service for its supported recovery process; never provide recovery credentials to support.

- [Find the fee asset for your network](https://oathwallet.org/networks/fees)
- [Choose a network for USDT or USDC](https://oathwallet.org/networks/choose-token-network)
- [Check pending, confirmed or failed activity](https://help.oathwallet.org/articles/transaction-status)
- [Follow the receiving instructions](https://help.oathwallet.org/articles/receive-crypto)
- [Check Phantom or Trust Wallet account paths](https://help.oathwallet.org/articles/solana-address-path)

![Use Solana in Oath](https://oathwallet.org/help/assets/guide-chain-solana.webp)

Oath 4.0.3. Existing app capture with sample data. Appearance can differ in newer releases; this image is not a completed transfer.

Product guidance for Oath 5.0.2 (104); updated 2026-11-06. [How we review guides](https://oathwallet.org/about#editorial).

<!-- token-catalog:start -->
## Tokens on Solana

Native coin: SOL. 7465 catalog token entries.

- [USDC (USDC) on Solana](https://oathwallet.org/tokens/usdc/solana)
- [Tether (USDT) on Solana](https://oathwallet.org/tokens/usdt/solana)
- [Jupiter (JUP) on Solana](https://oathwallet.org/tokens/jupiter-exchange-solana/solana)
- [Jito (JTO) on Solana](https://oathwallet.org/tokens/jito-governance-token/solana)
- [PayPal USD (PYUSD) on Solana](https://oathwallet.org/tokens/paypal-usd/solana)
- [Bonk (BONK) on Solana](https://oathwallet.org/tokens/bonk/solana)
- [Raydium (RAY) on Solana](https://oathwallet.org/tokens/raydium/solana)
- [Render (RENDER) on Solana](https://oathwallet.org/tokens/render-token/solana)
- [Pyth Network (PYTH) on Solana](https://oathwallet.org/tokens/pyth-network/solana)
- [dogwifhat (WIF) on Solana](https://oathwallet.org/tokens/dogwifcoin/solana)
- [.png (.PNG) on Solana](https://oathwallet.org/tokens/png/solana)
- ["　" ("　") on Solana](https://oathwallet.org/tokens/6/solana)

[Browse all Solana tokens](https://oathwallet.org/networks/solana/tokens). Catalog inclusion is not issuer verification or individually tested sending.
<!-- token-catalog:end -->

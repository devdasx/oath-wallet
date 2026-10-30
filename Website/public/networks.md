# Oath Wallet Supported Networks

Choose the exact network before sharing an address. A matching ticker, logo or address prefix does not make networks interchangeable.

## Source and availability

This list follows all 36 networks in the [4.1.14 (98) import catalog](https://github.com/devdasx/oath-wallet/blob/v4.1.14/OathAtmosphere/Import/OathImportCatalog.swift), checked October 30, 2026. Build 98 is a source release with no Apple upload or review submission; installed versions can differ. Availability of tokens, imports and sending actions depends on the chain, wallet type and provider configuration.

## Bitcoin family

- Bitcoin
- Bitcoin Cash
- Litecoin
- Dogecoin

## Ethereum-compatible networks

- Arbitrum
- Arc
- Avalanche C-Chain
- Base
- BNB Smart Chain
- Ethereum
- Fantom
- Flare
- Gnosis
- Linea
- Optimism
- Polygon
- Celo
- Monad
- Unichain
- HyperEVM
- Robinhood Chain
- Scroll
- Somnia
- Story
- Taiko
- Telos
- X Layer

## Other account networks

- Aptos
- NEAR Protocol
- Solana
- Stellar
- Sui Network
- THORChain
- Gram
- TRON
- XRP Ledger

## Addresses, fees and recovery

Bitcoin address choices depend on the imported material. Compatible wallets can use Taproot, Native SegWit, nested SegWit and Legacy. Silent Payments receiving and discovery are not supported in 4.1.14. Electrum and aezeed imports recover supported Bitcoin accounts; aezeed does not restore Lightning channels or arbitrary custom LND accounts.

For an EVM token, check its chain and contract. The same 0x address format on several chains does not bridge assets between them. Arc uses USDC as its native fee asset; most other networks require their own native fee asset. Check the network and fee shown before signing.

Gram is the name used for the TON network in this source. Token identifiers, account reserves, activation costs, memos and destination tags differ by chain. A network appearing here does not mean every historical wallet format or token is supported.

## Before receiving

- Select the intended wallet, asset and network in Receive.
- Confirm that the sender offers that same network and asset deployment.
- Compare the complete destination; include a memo or tag when the receiving service requires it.
- Use your own app address, never an address from a help screenshot.
- Verify a restored account against a known original address before relying on it.

Read the [receiving guide](https://help.oathwallet.org/articles/receive-crypto), [import guide](https://help.oathwallet.org/articles/import-recovery-phrase), and [security model](https://oathwallet.org/security).

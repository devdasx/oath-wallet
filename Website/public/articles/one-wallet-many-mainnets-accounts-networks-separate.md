# One Wallet, Many Mainnets: How Oath Keeps Accounts and Networks Separate

Oath Editorial · August 30, 2026

https://oathwallet.org/articles/one-wallet-many-mainnets-accounts-networks-separate

One Oath wallet can manage many mainnet identities, but every address, asset, balance, fee, nonce, and transaction remains attached to its exact network.

A multi-chain wallet can create a dangerous illusion: everything appears in one app, so everything must belong to one account. It does not. Oath gives you one coherent wallet experience while keeping the cryptographic identities, assets, balances, fees, nonces, and transaction histories of each mainnet in their proper lanes.

That separation is not visual housekeeping. It is part of the wallet’s safety model. A network name changes which ledger you are reading, which account identity is valid, which token contract defines an asset, which native coin pays the fee, and where a signed transaction can become final.

One interface can hold many mainnets. It must never pretend those mainnets are one ledger.

![Real Oath home screen in the iOS Simulator showing Ethereum, Bitcoin, Solana, BNB Smart Chain, and TRON assets in one wallet](https://oathwallet.org/assets/articles/ade80505c278-oath-home-multi-mainnet.webp)



A fresh capture from Oath 2.40.12 in the iOS Simulator. One test wallet presents Ethereum, Bitcoin, Solana, BNB Smart Chain, and TRON together without collapsing their network identities.

## The mental model: wallet, account, asset

Three words are often used as if they mean the same thing. In Oath they describe three different layers:

- 

Wallet. The user-owned container and recovery scope. A recovery-phrase wallet can deterministically derive the supported mainnet accounts that belong to it. Oath stores the secret material in its protected Keychain vault, not in the portfolio database.

- 

Network account. A public identity for one exact mainnet: network ID, validated address, public key, derivation path, and account index. One wallet owns many of these records.

- 

Asset. A native coin or token on one network. A token is identified by its network plus its canonical contract, mint, type, or issued-asset identity—not by a ticker or display name.

A holding then joins one network account to one asset. A transaction joins the same account and network to a transaction hash. This is why the app can sum values into one portfolio while still knowing exactly which ledger owns every row.

## Oath derives real accounts for every supported mainnet

When a full recovery-phrase wallet is created or imported, Oath derives and validates its supported account-zero identities through canonical Wallet Core coin APIs and chain-specific address rules. The result is not one generic address copied everywhere. It is a complete set of public account records produced from one deterministic recovery credential.

Bitcoin-family accounts use their own derivation and address formats. Aptos, Stellar, TRON, Solana, TON, Sui, Near, and XRP each use the key and address rules appropriate to that chain. Oath verifies the derived address before it becomes a persisted account. A newly supported non-EVM network cannot silently inherit the Ethereum address because EVM compatibility is a positive allowlist, not a guess.

![Real Oath Receive selector in the iOS Simulator showing separate Sui, Near, XRP, Ethereum, BNB Smart Chain, Arbitrum, Base, and Polygon mainnets](https://oathwallet.org/assets/articles/72cc27930f97-oath-network-list-mixed.webp)



Real Simulator output. Sui, Near, XRP, Ethereum, BNB Smart Chain, Arbitrum, Base, and Polygon are separate destinations even when several of them use EVM technology.

## The EVM exception: one address, separate chain state

Supported EVM-compatible mainnets can reuse the same proven secp256k1 public-key identity. That means the same hexadecimal address can appear on Ethereum, BNB Smart Chain, Arbitrum, Base, Polygon, Optimism, and other supported EVM networks. Oath persists one validated account record per network, and those EVM records must agree on the same normalized address and public key.

The shared address is a cryptographic convenience. It does not merge the chains. Each mainnet still has its own:

- 

Balance and token holdings. ETH on Ethereum and ETH on Arbitrum are independent ledger entries. A token contract on one chain is not the same asset as a look-alike contract on another.

- 

Nonce and transaction history. Sending on Ethereum advances Ethereum state, not BNB Smart Chain state. Explorers and receipts are network-specific.

- 

Native fee asset. The network decides which native coin pays validators or sequencers. Having value at the same address on another chain cannot pay this chain’s fee.

- 

Chain identity and finality. A transaction is encoded, signed, submitted, and confirmed under the selected network’s rules. The address alone does not choose the destination ledger.

![Real Oath Ethereum receive screen in the iOS Simulator with an explicit Ethereum Network label and public article-only test address](https://oathwallet.org/assets/articles/a9a91a8687f1-oath-receive-ethereum-address.webp)



Real Oath output. The destination is explicitly labeled Ethereum Network. The public address belongs to an empty article-only Simulator wallet; no recovery phrase or private key is present in the image.

![Real Oath BNB receive screen in the iOS Simulator with an explicit BNB Smart Chain Network label and the same validated EVM test address](https://oathwallet.org/assets/articles/ddd45afa8242-oath-receive-bnb-address.webp)



The hexadecimal address matches the Ethereum screen, but the selected ledger, native asset, network label, safety instruction, and receive request are BNB Smart Chain-specific. Same address does not mean same balance or same network.

## Non-EVM accounts do not borrow the Ethereum identity

On a non-EVM chain, the account is derived with that chain’s supported key type, path, public-key encoding, checksum, and address format. A Stellar address beginning with G, a Solana base58 address, an XRP classic address, and a Bitcoin address are not alternate spellings of the EVM address. They are different public identities governed by different protocols.

![Real Oath Stellar receive screen in the iOS Simulator with a Stellar-specific public address and network safety instruction](https://oathwallet.org/assets/articles/e33a66e30789-oath-receive-stellar-address.webp)



Real Oath output from the same empty test wallet. Stellar has its own public account address and an explicit instruction to send only XLM on the Stellar network.

This separation matters during both recovery and signing. A full wallet can derive all of its supported chain accounts from the same recovery credential, but it still signs each chain with the correct account material. A private-key import is narrower: an EVM key may cover supported EVM mainnets that reuse the proven address, while a non-EVM private key remains restricted to the network for which Oath validated it.

## A ticker is not an asset identity

Symbols are labels for people, not globally unique identifiers. ETH can be the native fee asset on several EVM networks. USDC exists through different contracts or issued-asset models on different chains. Unrelated tokens can even reuse a familiar symbol. Oath therefore resolves an asset by network plus its canonical on-chain identity. Native assets use the network plus a native marker; tokens use the network plus their exact contract, mint, Move type, account, or issued-asset identity.

![Real Oath Receive screen filtered to Stellar, showing Stellar XLM and Stellar USD Coin only](https://oathwallet.org/assets/articles/5635d616467c-oath-receive-stellar-filter.webp)



Real Simulator output filtered to Stellar. The visible XLM and USD Coin rows are Stellar variants, not generic symbols detached from a network.

- 

Logos do not prove identity. Oath uses official bundled network art and contract-aware token artwork, but the network and canonical on-chain identifier remain authoritative.

- 

Names do not prove identity. Searching for “USD Coin” is discovery; selecting the exact network variant is the security decision.

- 

Bridges do not happen automatically. Receiving or sending on one network does not teleport the asset to another. A bridge is a separate protocol action with separate risks.

## The network filter is a safety control

Oath’s Receive and Send discovery screens keep network selection visible because the same wallet can legitimately contain many destinations. “All” is useful for discovery. A specific mainnet filter narrows the list to assets whose identity belongs to that network.

![Real Oath Receive screen in the iOS Simulator with an All network filter and mainnet-specific asset rows](https://oathwallet.org/assets/articles/97d72ad1fb58-oath-receive-network-selector.webp)



Real Simulator output. Every row is backed by an exact asset variant, and the horizontal mainnet selector can reduce the catalog before an address is shown.

The ordering is contextual without changing identity. Networks with current local-currency value or activity may be easier to reach, but ranking never rewrites the network ID, address, or asset contract. A refreshed balance can move a row; it cannot turn an Ethereum asset into a BNB Smart Chain asset.

## Receiving: verify the ledger before the address

Oath resolves the receive address from the selected wallet’s persisted account for the chosen blockchain. Independent-address chains must pass their chain-specific validator. EVM chains use the validated shared EVM identity only when the selected network is positively known to be EVM.

- 

Choose the asset and exact mainnet in Oath. Do not start with an address copied from an old message.

- 

Read the network label above the QR code and the safety instruction below the address.

- 

Make the sender or exchange use that same network. A matching EVM address is not enough.

- 

For meaningful value, send a small supported test amount first and wait for it to appear on the intended network.

- 

Keep the native fee asset for future movement. Receiving a token does not automatically provide gas.

When an exchange shows several withdrawal networks for the same symbol, compare the full network name on both sides. Fees and speed are secondary; compatibility is the first requirement.

## Sending: the selected asset carries its network with it

Oath’s global Send action begins with network-aware asset selection. Sending from an asset detail screen already owns one exact asset and network variant, so it goes directly to the recipient step without asking you to choose again. The selected variant carries its network ID, source account, native-or-token identity, exact balance, decimals, and contract or mint into review and signing.

The network also determines address validation, amount encoding, fee estimation, signing logic, provider, explorer, and broadcast method. Review is therefore about more than the recipient and amount. It is the final chance to verify the complete tuple: asset, network, recipient, amount, and network fee. Read [Send coins and tokens](https://help.oathwallet.org/articles/send-availability) for the full flow and [Where Crypto Network Fees Actually Go](https://oathwallet.org/articles/where-crypto-network-fees-actually-go) for the fee model.

## What stays separate behind the interface

Oath’s portfolio database keeps the boundaries explicit rather than inferring them from display strings:

- 

Wallet record. Name, wallet kind, selection state, backup state, appearance, and an opaque reference to protected secret material.

- 

Network account record. Wallet ID plus network ID, public address, normalized address, public key, derivation path, and account index.

- 

Asset record. Network ID plus native/token type and the exact canonical contract or equivalent on-chain identity.

- 

Holding record. One account joined to one asset with lossless text balances and visibility state.

- 

Transaction record. Account ID and network ID beside the transaction hash, asset, amount, fee, nonce where applicable, and status.

This model prevents a convenient label from becoming a source of truth. It also lets Oath total a portfolio without sacrificing the boundaries needed for Send, Receive, synchronization, fee calculation, and transaction details.

## Recovery phrase wallets and private-key wallets are intentionally different

A recovery phrase is a deterministic root. Oath can derive the complete supported full-wallet account set, validate it, and persist the public identities atomically. A private key proves a much smaller scope. Oath does not pretend one child key can reconstruct the original seed or unrelated chain accounts.

- 

Full recovery-phrase wallet. Network selector and asset management are available across the supported mainnet set. Each chain still receives its correct account identity.

- 

EVM private-key wallet. The proven EVM address may be used across supported EVM-compatible mainnets, with independent chain state on each one.

- 

Non-EVM private-key wallet. The wallet remains scoped to the single validated network. It cannot acquire an Ethereum identity merely because another chain is visible elsewhere in the app.

For a precise comparison of recovery scope, read [Recovery Phrase, Private Key, iCloud, or iPhone Transfer?](https://oathwallet.org/articles/recovery-phrase-private-key-icloud-iphone-transfer-import).

## Mainnet only means fewer ambiguous destinations

Oath supports production mainnets only. It does not mix testnet balances, faucets, test tokens, or test transaction histories into the portfolio. That removes one entire class of network confusion, but it does not remove the need to distinguish one mainnet from another. Ethereum mainnet and BNB Smart Chain mainnet are both real ledgers with real value—and they are still separate.

## Seven mistakes the architecture is designed to expose

- 

“The address matches, so the network must match.” Several EVM mainnets can share the address. Read the network label.

- 

“The ticker matches, so the token must match.” The network and exact contract or issued-asset identity decide what the token is.

- 

“I have ETH somewhere, so I can pay this fee.” The fee asset must exist on the network where the transaction will be submitted.

- 

“One private key restores my whole wallet.” It restores only the account scope the key can prove.

- 

“A wallet app balance is one universal balance.” The total is an aggregation of network-scoped holdings, not an on-chain account.

- 

“Sending to the same EVM address moves value between chains.” A transfer stays on its selected chain. Cross-chain movement requires a separate bridge or exchange workflow.

- 

“The explorer says nothing happened.” You may be looking at the right address on the wrong network explorer.

## A practical preflight for every transfer

- 

Which exact mainnet will record this transaction?

- 

Is the selected asset the native coin or the exact token contract/mint on that mainnet?

- 

Does the recipient support that same network and address format?

- 

Which native asset will pay the fee, and is enough of it available on this network?

- 

Am I reading the correct network explorer and expected finality model?

- 

If the value matters, have I tested the route with a small amount first?

## One wallet should reduce work, not erase boundaries

Oath’s job is to make many networks understandable without making them look interchangeable. The wallet switcher gives you one place to manage the self-custody identity. The portfolio gives you one total. Search and selectors give you one way to find assets. Underneath, every account, asset, holding, transaction, fee, and receive address retains its exact mainnet context.

That is the balance a serious multi-chain wallet must keep: one coherent experience for the person, many uncompromised ledgers for the cryptography.

One wallet. Many validated accounts. Every asset and transaction stays on the network that actually owns it.

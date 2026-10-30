# Oath 2.40.12: Monero, Major Bitcoin Upgrades, and Safer Sending

Oath Editorial · September 2, 2026

https://oathwallet.org/articles/oath-2-40-12-monero-bitcoin-safer-sending-wallet-tools

Oath 2.40.12 adds complete Monero mainnet support, five Bitcoin receiving standards, EVM permission controls, safer sending, local wallet tools, seven languages, and system-wide reliability improvements.

Oath 2.40.12 is a broad technical release built around one practical goal: give you more control without making self-custody harder to understand. It introduces Monero, turns Bitcoin into a much more complete address-management environment, makes sending more deliberate, adds tools that stay on the device, and improves the consistency of data across the wallet.

This guide explains what changed, what each feature actually does, and the boundaries that still matter. It documents the 2.40.12 build itself. App Store review and regional rollout can make the version shown by Apple differ temporarily, so confirm the installed version in Settings → About after updating.

The theme of 2.40.12 is visible control: clearer network identity, clearer signing decisions, clearer recovery tools, and fewer places where the same wallet data can disagree with itself.

## The release at a glance

- 

Monero becomes a first-class mainnet. Oath can derive an XMR account for compatible recovery-phrase wallets, synchronize balances and history, receive, estimate fees, send, broadcast, and follow confirmation state.

- 

Bitcoin gains multiple wallet languages. Electrum Standard and Electrum native SegWit seeds can be recognized, while BIP39 wallets can use BIP44, BIP49, BIP84, BIP86, and BIP352 Silent Payments.

- 

Bitcoin Settings becomes a real control surface. Discovery, receive and change branches, address state, manual selection, extended public keys, balance statistics, and address-level WIF export are visible in one flow.

- 

Sending becomes harder to do twice or do blindly. Recent recipients, memo and destination-tag context, live-fee checks, a dedicated amount keypad, post-broadcast monitoring, and durable spend reservations tighten the entire path.

- 

New local tools fill important gaps. EVM permission review, a multi-market converter, a signed Bitcoin transaction broadcaster, a BIP39 final-word finder, and private-key export are now available where they belong.

- 

The rest of the app catches up. Receive, Wallet Switcher, Security, App Shortcuts, asset information, artwork, pricing, accessibility, localization, and performance all receive meaningful work.

## Full Monero mainnet support

Monero is not being presented as an EVM-shaped account with a different logo. Oath 2.40.12 adds a native XMR path from wallet identity through synchronization and transaction submission. For a compatible BIP39 recovery-phrase wallet, Oath derives the Monero spend identity deterministically and validates the resulting mainnet address before it is stored or used. Bitcoin-specific Electrum seed wallets remain Bitcoin-specific; the app does not pretend an incompatible seed scheme can produce the same multi-chain wallet.

Monero uses 12 decimal places, and Oath preserves amounts in atomic units while converting them for display. Synchronization distinguishes the wallet’s total balance from the amount currently unlocked for spending. That matters because newly received outputs can appear in history before they are spendable under Monero’s confirmation rules.

### Receive XMR with an address or QR code

Choose Monero in Receive and Oath presents the derived mainnet address and a scannable QR code. The Send scanner also recognizes valid Monero payment requests. The app validates Monero’s address encoding and mainnet length instead of accepting a string merely because it looks long. As with every chain, verify both the asset and the network on the sending service before using the destination.

### Live fee estimates, then an authoritative built fee

Oath asks Monero node infrastructure for current fee-rate data and uses a conservative transaction-weight envelope for the early estimate. When the actual transaction is prepared, the native Monero wallet engine chooses inputs, constructs outputs, and calculates the real fee. That final built fee—not the earlier display approximation—is the amount attached to the signed transaction. Economy, Standard, and Fastest map to Monero transaction priorities; a generic custom gas field would be misleading here, so Oath does not invent one.

### Sign, broadcast, and keep watching

Before signing, Oath re-derives and checks the account identity, validates the recipient, confirms the amount is representable in atomic units, and synchronizes the wallet state needed to select spendable outputs. The signed transaction is broadcast to Monero mainnet, its transaction ID is recorded locally, and the status screen continues checking whether the network has accepted and confirmed it. If a network interruption happens after submission may have started, Oath reports an uncertain outcome and keeps the transaction ID available for verification instead of encouraging an immediate duplicate send.

Monero privacy does not mean invisible networking. Public node infrastructure can observe connection metadata and request timing even though it never receives the private spend key. Use network privacy practices appropriate to your own threat model.

## Bitcoin imports now respect the seed you actually have

“A list of words” is not one universal format. BIP39 and Electrum seeds use different validation and derivation rules. Treating one as the other can open an empty wallet even when every word was typed correctly. Oath 2.40.12 detects and preserves the scheme instead of forcing every phrase through a BIP39 assumption.

- 

Electrum Standard. Oath recognizes Electrum’s standard seed-version marker and derives its legacy Bitcoin account from the Electrum root rules.

- 

Electrum native SegWit. Oath recognizes the Electrum SegWit seed marker and derives the native SegWit account from Electrum’s SegWit account path.

- 

BIP39. A valid BIP39 phrase continues to produce the multi-chain wallet and Bitcoin account families described below. An optional BIP39 passphrase remains part of the wallet identity.

Electrum two-factor seed variants are not silently downgraded to ordinary seeds. If a scheme is unsupported, stop and use software that explicitly supports that source wallet. Never “convert” a recovery phrase by changing or rearranging its words. For the technical distinction, see [Electrum’s seed-version documentation](https://electrum.readthedocs.io/en/latest/seedphrase.html) and the [BIP39 specification](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki).

## Four deterministic Bitcoin address families—plus Silent Payments

For a BIP39 wallet, 2.40.12 exposes four standard deterministic account families. Each family derives a separate receive branch and change branch. Choosing a type does not translate an existing address or move bitcoin; it tells the wallet which script and derivation path to inspect and present.

- 

BIP44 Legacy. Classic pay-to-public-key-hash addresses commonly begin with 1. They offer broad historical compatibility but use more block space than SegWit formats.

- 

BIP49 Nested SegWit. SegWit is wrapped in a compatibility script and addresses commonly begin with 3. This was an important bridge for services that did not yet understand native SegWit.

- 

BIP84 Native SegWit. Bech32 addresses begin with bc1q. This is Oath’s default standard Bitcoin type because it avoids the compatibility wrapper while retaining wide modern support.

- 

BIP86 Taproot. Pay-to-Taproot addresses begin with bc1p. They use Taproot key-path output rules and must be sent through software that supports Taproot.

- 

BIP352 Silent Payments. A reusable public payment instruction beginning with sp1 lets compatible senders derive a unique Taproot destination for each payment. Oath scans for those unique outputs; it does not reuse one on-chain address.

The standards are defined separately in [BIP44](https://github.com/bitcoin/bips/blob/master/bip-0044.mediawiki), [BIP49](https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki), [BIP84](https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki), [BIP86](https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki), and [BIP352](https://github.com/bitcoin/bips/blob/master/bip-0352.mediawiki). Oath keeps them separate because their paths, scripts, address encodings, discovery rules, and interoperability are not interchangeable.

## Bitcoin Settings: see the account behind the balance

The new Bitcoin Settings area turns address derivation from hidden machinery into inspectable wallet state. It is organized by account type so Legacy, Nested SegWit, Native SegWit, Taproot, and Silent Payment output discovery cannot blur together.

### Address discovery and the two chains

A deterministic Bitcoin account has an external branch for receive addresses and an internal branch for change. Oath scans both, checks address history and unspent outputs, and preserves a gap of 20 unused addresses during automatic discovery. This lets it find activity beyond the first address without searching an unbounded range.

You can generate more public address records through a chosen index, up to 1,000 additional indexes in one operation. Private child keys are not copied into the wallet database; they remain derivable from the Keychain-backed wallet secret when needed.

### Status, selection, and balance statistics

Each generated address can show its index, whether it is used or unused, whether it is current or reserved, and its confirmed and unconfirmed balance. You can make an unused receive address current or return to automatic selection. A manually selected receive address remains current until it is used. A manually selected change address is reserved for the next Bitcoin send, so it cannot be casually reused by two competing drafts.

Account statistics summarize used and reserved addresses, while the wallet’s combined Bitcoin balance can include discovered value across BIP44, BIP49, BIP84, BIP86, and Silent Payment outputs. The total is unified; the ownership records remain path-specific.

### Extended public keys are powerful public data

Bitcoin Settings can reveal the extended public key for the selected account. An extended public key cannot sign or spend, but it can derive the account’s public addresses and expose its transaction graph to anyone who receives it. Treat it as sensitive financial metadata: share it only when you intentionally want another wallet or service to watch the account.

### Address-level WIF export

Oath can export the Wallet Import Format private key for a specific derived Bitcoin address. This is not a backup of the whole HD wallet. It controls only the output path represented by that key, and compatible software still needs to understand the address type. A discovered Silent Payment output can likewise expose its unique Taproot output key when required.

Anyone who sees a WIF can spend bitcoin controlled by that key. Never paste it into a website, message it to support, store it in photos, or scan it on an untrusted device. If exposure is possible, treat the key as compromised and move the affected funds.

## Physical randomness now checks for obvious failure patterns

Building entropy from coin flips, dice rolls, or random digits depends on two things: a fair independent source and an exact transcription of every outcome. Version 2.40.12 adds a live input-health check for three strong warning classes: extreme consecutive repetition, one outcome dominating the sequence far beyond expectation, and unusually predictable cycles.

The checker is intentionally modest. Passing does not prove randomness, and a warning does not authorize you to “balance” the sequence by choosing future results. If the newest value was entered incorrectly, undo that transcription error. Otherwise, inspect the physical source, clear the sequence, and restart with fair independent events. Human correction is itself a predictable process and should never be mixed into entropy.

The entropy-to-mnemonic calculation remains local. No dice result, coin flip, random digit, recovery phrase, or optional passphrase is uploaded to Oath. Read the complete workflow in [Make Randomness Physical](https://oathwallet.org/articles/build-wallet-with-dice-coin-flips-random-digits).

## EVM Access: local connections and on-chain authority are different

Disconnecting a dApp session and revoking a token permission solve different problems. A local disconnect removes the session Oath knows about. It does not edit an ERC-20 allowance or an NFT contract on-chain. EVM Access makes both layers visible so “Disconnected” cannot be mistaken for “No longer authorized.”

- 

Connected dApps. See locally known sessions, their origin, and the number of accounts and networks in scope, then disconnect the session from Oath.

- 

ERC-20 allowances. See which spender can transfer a token and whether the current allowance is limited or effectively unlimited.

- 

NFT token approvals. See a spender authorized for a particular token ID.

- 

NFT operator access. See broader collection-level authority granted through an operator approval.

Permission discovery combines relevant approval events with current contract reads on each supported EVM mainnet. That current-state check matters: an old approval event may already have been replaced or revoked. If one network cannot be verified, Oath keeps verified results from the others and identifies the partial failure rather than pretending the scan was complete.

Revocation is a real on-chain transaction. Oath builds the appropriate contract call, obtains a current gas estimate, shows the spender, contract, permission type, and fee, then signs only after authorization. The revocation remains pending until the selected network confirms it, and that network charges its normal fee. Revoking on Ethereum does not revoke a separate approval on Base, Arbitrum, or any other chain.

## Five practical tools, each with a clear boundary

### 1. Crypto, fiat, gold, and silver converter

The converter lets any visible row become the input, then updates the other selected units around it. You can combine supported crypto assets, national currencies, gold, and silver; reorder the set; and optionally keep the tool available from Home. Saved values can make the view useful immediately while live market and exchange-rate sources refresh. These are informational reference values, not executable quotes or promises of what an exchange will pay.

### 2. Signed Bitcoin transaction broadcaster

Paste, type, or scan a complete signed Bitcoin mainnet transaction in hexadecimal form. Oath validates the payload, derives a transaction ID preview, and submits the existing signed bytes to Bitcoin network infrastructure. The tool does not ask for a private key and does not create or alter the transaction. Review the transaction in the signing environment before bringing it here; broadcasting is the irreversible publication step.

If the node rejects the transaction, Oath shows the rejection. If connectivity fails after acceptance may have occurred, it reports the outcome as unknown and preserves the transaction ID so you can check a block explorer before trying again.

### 3. Local BIP39 final-word finder

BIP39’s last word contains both entropy and a checksum. Enter the first 11, 14, 17, 20, or 23 words and Oath calculates every checksum-valid final word locally. The text stays transient, is cleared when you leave the screen, and is never sent to a server.

A checksum-valid candidate is not proof that it is the word from your backup. The tool narrows mathematically valid completions; it does not identify which wallet is yours, recover a missing passphrase, or make it safe to type a recovery phrase into websites. Compare candidates only in a private environment you control.

### 4. Secure private-key export

Wallet Management can now expose chain-specific private-key material after wallet authorization. Oath shows the network and derivation path, uses the appropriate format—such as hexadecimal, compressed or uncompressed Bitcoin WIF, or a Solana Base58 seed or keypair—and masks the sensitive view when the app leaves the active foreground. Clipboard copies are local to the device and expire after two minutes.

The export is intended for deliberate interoperability and recovery, not routine sharing. One BIP39 phrase can produce different keys for different paths; compatible EVM networks can share the same Ethereum account key; and Solana software may use different derivation conventions. Match the exact network, path, and format before importing anywhere.

### 5. EVM Access

The connection and permission manager is a tool in its own right: it turns invisible local sessions and persistent contract approvals into separate, reviewable records. Because a revoke costs gas and changes blockchain state, it uses the same explicit review, signing, submission, and confirmation discipline as a transfer.

## Sending is safer from recipient entry to finality

The Send flow now carries more context forward and rejects more uncertainty before signing. The changes are not one warning screen; they tighten the sequence from recipient selection through the period after broadcast.

### Recently used recipients with memo context

For the selected wallet and account, Oath can show recipients from previous accepted transfers. It distinguishes a new address from one used once or several times and preserves the associated memo or destination tag when the network requires one. That history is context, not proof of identity: malware, address poisoning, and a mistaken earlier payment can all make a familiar string unsafe. Always compare the complete address and the current memo or tag.

### A dedicated amount keypad

The new keypad accepts ASCII digits and one decimal separator, respects the selected asset’s precision, and keeps crypto and local-currency entry synchronized without relying on a locale-shaped system keyboard. Max remains transaction-aware: the app must reserve the network fee and any protocol-specific minimums before it can decide what “all” means.

### Live-fee validation and warnings

Fee presets and custom values are evaluated against current network data, the actual recipient and amount, the account balance, and the selected chain’s fee model. A stale or incomplete quote is not relabeled as live. If Oath cannot verify the balance or current price needed for a safe custom value, it keeps the control unavailable and exposes the concrete condition.

### Post-broadcast monitoring

After a transaction is submitted, the status screen does not stop at “sent.” It polls the relevant mainnet for acceptance, execution failure, and confirmation, reconciles the local activity record, and keeps the transaction hash available for independent verification. Some chains can accept a transaction that later fails during execution; that is different from a transaction rejected before broadcast.

### Protection against overlapping sends

Before submission, Oath writes a durable spend reservation for the selected account. A second send from that same spend source cannot race ahead while the first is still preparing, broadcasting, or unresolved. If the app restarts, it can reconcile the stored transaction evidence with the network instead of assuming the lock vanished. Terminal or definitively rejected transactions release the reservation; uncertain outcomes remain protected until they can be resolved.

A pending transaction is not permission to send the same payment again. Verify the transaction hash and network state first.

## One live balance source across Home, asset lists, and Send

Different screens should not tell different financial stories. In 2.40.12, Home, asset lists, and Send consume the same published live wallet dataset rather than building competing balance snapshots on their own schedules. A completed refresh updates the shared source; dependent screens then render from the same revision.

This removes a class of confusing states in which Home showed one amount while Send calculated another. It does not turn pending blockchain state into certainty: confirmed, unconfirmed, locked, reserved, and spendable values can still differ for protocol reasons. The improvement is that every screen receives the same evidence and applies the appropriate rule to it.

## Receive: easier to share, harder to misread

- 

Share the QR itself. In addition to copying or sharing the address text, you can share the generated QR image when that is the clearest way to move a receive request between devices.

- 

A safer scanner. Scanned content is parsed and reviewed as a typed payment request, recipient, recovery credential, or other supported payload before the destination flow uses it. A QR code is an encoding, not a trust signal.

- 

Remember the last standard Bitcoin type. Silent Payments is a special reusable instruction, not the default fallback for every receiver. After using Silent Payments, Oath remembers the last conventional BIP44, BIP49, BIP84, or BIP86 choice and returns to it when the next context needs a standard address.

The same core rule still applies: confirm the exact network and asset before sharing any receive destination. A familiar symbol cannot prove cross-chain compatibility.

## Create, import, and restore without leaving Wallet Switcher

Wallet Switcher is no longer only a chooser. Its add-wallet flow can create a new recovery-phrase wallet, build one from physical randomness, import supported recovery phrases or private keys, and restore an encrypted iCloud backup directly inside the switcher’s navigation stack. When setup succeeds, the new wallet becomes available without forcing you through a separate onboarding shell.

Every route keeps its own validation and duplicate-wallet checks. A recovered wallet is still the wallet produced by the exact credential and passphrase; adding it from a more convenient place does not change the cryptography or create a server account.

## Security settings explain their consequences

Passcode entry now uses clearer haptic feedback so success, selection, and failure are easier to distinguish without depending only on color. Controls for turning the app passcode on, changing it, and turning it off use more direct language. The disable warning makes the consequence explicit: turning off the passcode also turns off biometric unlock and automatic locking, leaving Oath available to anyone who can access the device.

Require Passcode now offers a broader set of timings: immediately, after 1 minute, 5 minutes, 15 minutes, 1 hour, or 4 hours. A shorter interval reduces the unattended-access window; a longer one favors convenience. App Switcher Privacy remains a separate control for concealing balances in multitasking previews. None of these controls replaces a recovery backup, and forgetting an optional wallet passphrase still creates a different wallet that Oath cannot recover.

## Six App Shortcuts put common destinations at system level

Oath 2.40.12 publishes App Shortcuts for Search, Receive, Currency Converter, Security, Wallet Management, and Build Your Entropy. They can appear in Apple’s Shortcuts surfaces and open the corresponding Oath destination directly. The wallet’s existing app-lock state still controls access after the app opens; a shortcut is navigation, not authentication.

## Asset context, discovery, artwork, and pricing

Native asset detail pages can now include an informational Wikipedia summary and source link. This is reading context, not token verification: a description cannot prove that a contract address is genuine. Token identity continues to depend on the exact network and normalized contract address, and custom assets must be checked against an authoritative issuer source.

Behind the screen, discovery refreshes, bundled token artwork, fallback artwork, and price coverage have been made more reliable. The important user-facing result is fewer stale assets, fewer mismatched images, and a better chance of attaching price data to the exact asset record. An unavailable price remains unavailable; it should not become a guessed zero or a borrowed quote from a matching ticker.

## Seven new languages

This release adds Croatian, Georgian, Malay, Norwegian Bokmål, Portuguese for Portugal, Slovak, and Slovenian. Translation work includes the new Monero, Bitcoin, EVM Access, Send, Receive, security, and tool flows—not only the navigation labels that lead to them. Numbers remain ASCII digits throughout the app so addresses, amounts, indexes, and cryptographic data are not reshaped by locale.

## The smaller improvements still matter

- 

Scan QR from Home. The scanner is available as a first-class wallet action, reducing the need to begin a send before identifying what a code contains.

- 

Rating and feedback. Prompts and feedback routes are clearer and less disruptive, with a cleaner distinction between an App Store rating and contacting support.

- 

Wallet deletion and reset guidance. Destructive actions explain what is removed from the device and what recovery material is required before proceeding.

- 

Native controls and labels. Buttons, navigation language, Dynamic Type behavior, accessibility descriptions, and state labels are refined across iPhone and iPad.

- 

Reliability and performance. Synchronization, caching, provider fallback, asset rendering, localization parity, and background task ownership receive fixes throughout the app.

## A careful upgrade checklist

- 

Update through the App Store, then confirm 2.40.12 in Settings → About when the rollout reaches your region.

- 

Before testing exports or imports, verify that your recovery phrase and any optional passphrase are recorded privately and accurately. Never use documentation examples as wallet credentials.

- 

Expect a newly enabled Monero wallet to synchronize before its complete history and unlocked balance are available. Do not compare a partially synchronized result with a fully synchronized wallet.

- 

When importing Bitcoin, let Oath recognize the seed scheme. Then inspect the expected address family and discovery results before receiving or sending.

- 

Open EVM Access network by network. Disconnect sessions you no longer use, then separately review on-chain allowances and NFT approvals.

- 

For any send, verify the asset, mainnet, full recipient, amount, memo or destination tag, and fee on Review. Keep the transaction hash until finality is clear.

## More capability, with the boundaries left visible

Oath 2.40.12 is large because self-custody is not one screen. It is seed compatibility, deterministic identity, address discovery, balance evidence, permission state, transaction construction, local authorization, network broadcast, and honest reporting after the fact. The release improves each layer while keeping their responsibilities separate.

Monero is handled as Monero. Bitcoin account types remain distinct. A dApp disconnect is not called a revocation. An estimate is not called a final fee. A submitted transaction is not called confirmed. A checksum-valid word is not called recovered. That precision is the feature underneath all the features.

For deeper guides, continue with [Oath’s self-custody security model](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model), [how Bitcoin fresh receiving addresses work](https://oathwallet.org/articles/why-bitcoin-wallets-generate-fresh-receiving-addresses), [Silent Payments in Oath](https://oathwallet.org/articles/silent-payments-oath-reusable-bitcoin-address-without-reuse), and [how network fees work](https://oathwallet.org/articles/where-crypto-network-fees-actually-go).

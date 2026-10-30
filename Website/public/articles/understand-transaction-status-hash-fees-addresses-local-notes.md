# Understand Any Transaction: Status, Hash, Fees, Addresses, and Local Notes

Oath Editorial · August 31, 2026

https://oathwallet.org/articles/understand-transaction-status-hash-fees-addresses-local-notes

Read an Oath transaction from status to settlement: verify its ID, separate the network fee, inspect both addresses, and attach a private local note.

A transaction is not one fact. It is a stack of facts: what your wallet tried to do, what a network accepted, which addresses were involved, what value moved, what the network charged, and how you want to remember the event later. Reading only the amount leaves too much room for error.

Oath’s Transaction Information screen separates those questions on purpose. Status and direction come first. The transfer amount and network fee live in different sections. Sender, recipient, and transaction ID can be opened in full. A note can be saved on the iPhone without changing the blockchain record.

A green status is the beginning of verification—not a reason to stop reading. Match the network, both addresses, the amount, the fee, and the transaction ID before you treat the record as settled.

## A real public transaction, not a mock screen

Every interface image in this guide is a real Oath 2.40.12 screen captured from the isolated iOS Simulator. To make the fields independently auditable without exposing a user’s wallet, the production detail view was loaded with a public Ethereum mainnet transfer and then the Simulator was restored. No funded Oath account, recovery phrase, private key, passcode, or user address appears in the captures.

The example transaction is [0xcb87a10a5e90a95b860ec6eb029956ff587c08db988f08f7c62a6f07ecf182b0 on Ethereum mainnet](https://etherscan.io/tx/0xcb87a10a5e90a95b860ec6eb029956ff587c08db988f08f7c62a6f07ecf182b0). A live mainnet RPC returned a successful receipt in block 25,875,394 with 21,000 gas used. The screenshot is a point-in-time record; the block naturally accumulated more confirmations after capture.

## Begin in Activity, then open the receipt

Activity gives you the wallet-level summary: direction, asset, amount, relative time, and a status badge. In the example, Oath shows a sent Ethereum transfer of 0.01184295 ETH. That row is useful for recognition, but it is intentionally not the complete proof. Open it before comparing details or answering a support question.

![Real Oath Activity screen in the iOS Simulator showing a confirmed public Ethereum mainnet send](https://oathwallet.org/assets/articles/fde85f4f84af-01-activity-real.webp)



Real Oath Activity screen. The amount is rounded for reading; the transaction detail and public receipt preserve the identity needed for verification.

## 1. Read the status—then separate confirmation from finality

Oath models four transaction states:

- 

Pending. The transaction has been submitted or its outcome is not yet terminal. It may be waiting for block inclusion, provider reconciliation, or a network-specific status update.

- 

Confirmed. Oath has received a successful terminal result for the transaction. On Ethereum, that means the transaction was included and its receipt reported success.

- 

Failed. Execution or submission reached a terminal failure. On fee-based networks, failure does not automatically mean that no network fee was consumed.

- 

Canceled. The activity record was canceled in a supported flow. Treat it as a distinct terminal state and verify the transaction ID or explorer record whenever value movement is uncertain.

“Confirmed” and “finalized” are related but not universal synonyms. Different blockchains use different consensus rules, confirmation counts, and finality models. Ethereum’s [transaction lifecycle](https://ethereum.org/developers/docs/transactions) moves from a generated hash to the pending pool, block inclusion, justification, and finalization. Its proof-of-stake documentation describes finality as a checkpoint state backed by validator votes, not simply the first successful receipt.

For everyday wallet reading, Oath’s confirmed status answers “did this network report a successful transaction?” It does not promise that every supported network has reached the same depth or economic finality at the same moment. For a high-value payment, apply the recipient or service’s required confirmation policy and inspect the matching network explorer.

![Real Oath Transaction Information screen showing confirmed status, timestamp, Ethereum network, recipient, sender, and transfer amount](https://oathwallet.org/assets/articles/32b3c477d483-02-transaction-overview-real.webp)



Real Transaction Information screen. The green status, exact timestamp, Ethereum identity, recipient, and sender are visible before the fee or transaction ID.

## 2. Direction tells you whose perspective you are reading

The same on-chain movement looks different depending on the selected wallet account. Oath uses direction to make that perspective explicit:

- 

Sent shows a negative asset amount because value left the selected account. For sent transfers, Oath places the recipient before the sender so the destination is easy to check first.

- 

Received shows a positive amount and places the sender before the recipient. The recipient still needs to confirm that the destination belongs to the intended account and network.

- 

Self-transfer means the wallet recognized both sides as part of the same ownership context. A network fee may still apply even when the economic destination is yourself.

- 

Swap represents an asset exchange. One transaction hash can contain several contract calls and token-transfer events, so the explorer may show more detail than one summary row.

The plus or minus sign is a wallet perspective—not part of the raw blockchain amount. The chain records values and participants; Oath derives whether the selected account received, sent, exchanged, or moved value to itself.

## 3. The transfer amount is not the total balance change

Transfer Amount answers “how much of this asset was moved?” It does not necessarily answer “how much did my account lose in total?” A sender on a fee-paying network normally spends the transfer amount plus a separate fee paid in the network’s native asset. A recipient usually receives the transfer amount and does not pay the sender’s fee.

In the public Ethereum example, the exact value field is 0.011842952936749721 ETH. Oath presents -0.01184295 ETH for a readable sent summary. That rounding is presentation only; the transaction ID is the durable key for retrieving the exact public receipt.

For token transfers, the asset being moved and the fee asset can differ. Sending an ERC-20 token, for example, moves the token while the Ethereum network fee is paid in ETH. Never subtract a token-denominated amount from a native-coin fee as if they were one unit.

## 4. Network fee is its own fact

Oath gives the network fee a separate section because it answers a different question: what did the network charge to process this operation? The fee is not an Oath service charge and does not go to the recipient. Its mechanics depend on the selected mainnet.

For this simple Ethereum transfer, the public receipt reports 21,000 gas used at an effective gas price of 1.091190433 gwei. Multiplying those values produces 0.000022914999093 ETH, which Oath displays as 0.00002291 ETH. The official [Ethereum gas documentation](https://ethereum.org/developers/docs/gas/) explains the same relationship: gas used multiplied by the cost per unit. Under EIP-1559, the effective cost includes the protocol base fee and a priority fee; the base fee is burned and the priority portion goes to the validator.

Three fee rules prevent common misreads:

- 

A fee is separate from the transfer amount. The recipient does not receive it.

- 

A failed transaction may still cost a fee. Ethereum charges for computation already performed even when execution reverts or runs out of gas.

- 

The displayed fee belongs to one network event. A bridge, swap, or multi-step workflow can create additional transactions with their own hashes and fees.

![Real Oath transaction screen showing the transfer amount, separate Ethereum network fee, empty local-note field, and on-device note disclosure](https://oathwallet.org/assets/articles/77280b4ddca7-03-fee-and-local-notes-real.webp)



Real Oath output. The transfer and fee are displayed in separate sections, followed by a note field whose footer states that notes stay on this iPhone and never enter the blockchain transaction.

For a deeper breakdown of who receives, burns, or collects fees across network families, continue with [Where Crypto Network Fees Actually Go](https://oathwallet.org/articles/where-crypto-network-fees-actually-go).

## 5. Sender and recipient are identities, not labels

The sender is the account that authorized the transaction. The recipient is the destination encoded by the transaction. On a simple native-coin transfer, that destination is usually another account. On a contract interaction, the recipient may be a smart contract while token-transfer logs describe the eventual asset recipients.

Oath abbreviates long identities in the overview so the screen remains readable. Tap a participant to open the complete address, then select the text when you need to compare or copy it. Do not verify only the first and last few characters: address-poisoning attacks are designed to make shortened strings look familiar.

![Real Oath Recipient sheet showing the complete public Ethereum destination address](https://oathwallet.org/assets/articles/dfe47416464e-06-recipient-address-real.webp)



Real Oath Recipient sheet showing the full public Ethereum destination. The address is public chain data, not a recovery phrase or private key.

Check addresses in this order:

- 

Network first. An Ethereum address displayed on Base, Polygon, or another EVM network is a different chain context even when the hexadecimal string is identical.

- 

Full destination second. Compare every character against the invoice, contact, or independently opened source.

- 

Direction third. Make sure you are not reading your own sender address as the intended recipient.

- 

Contract context last. For swaps and token transfers, use the network explorer to distinguish the called contract from transfer-event recipients.

## 6. The transaction ID is the receipt key

A transaction ID—often called a transaction hash—is a public identifier derived from the signed transaction. It is not a password, private key, passcode, or recovery phrase. Sharing it reveals the public transaction and its addresses, amounts, timing, and contract activity, but it does not grant spending authority.

Oath presents the complete ID in a dedicated sheet and pairs it with copy, share, and chain-specific explorer actions. The explorer destination is selected from the transaction’s network, so an Ethereum hash opens on Ethereum’s explorer rather than on a different EVM chain.

![Real Oath Transaction ID sheet showing the complete public hash with copy, share, and block-explorer actions](https://oathwallet.org/assets/articles/11a14bcd0908-05-transaction-id-actions-real.webp)



Real Oath Transaction ID sheet. The full hash matches the independently verified public mainnet receipt used for this guide.

Use the hash to answer questions the compact wallet view should not overload onto one screen:

- 

Was the transaction found on the intended network?

- 

Which block included it, and how old is that block now?

- 

Did execution succeed or revert?

- 

How much gas or network resource was actually consumed?

- 

Were there token-transfer events, contract calls, memos, or destination tags?

A block explorer is a read-only verification surface unless you deliberately connect a wallet or sign something. You do not need to enter a recovery phrase, private key, or passcode to inspect a transaction. If an explorer page or support message asks for one, leave immediately.

## 7. Local notes add context without rewriting history

Blockchains preserve protocol facts, not your reason for sending. “Rent,” “invoice 1042,” “hardware-wallet consolidation,” or “support case opened” are personal context. Oath lets you attach that context locally after the transaction exists.

Transaction notes accept up to 1,000 UTF-8 bytes. Oath trims surrounding whitespace, saves the normalized note in its local activity database, and exposes a delete action after saving. The note is not broadcast, cannot change the transaction, and is not visible to the recipient, validator, explorer, or anyone reading the chain.

![Real Oath transaction screen showing a saved device-local mainnet verification note and its delete action](https://oathwallet.org/assets/articles/69d06f30f3db-04-saved-local-note-real.webp)



Real saved-note state. The neutral example records that the public receipt was checked; the footer makes the privacy boundary explicit. The temporary transaction and note were removed when the isolated Simulator was restored.

Good notes explain intent without storing secrets. Useful examples include an invoice number, a contact name already safe to keep on the device, a tax lot label, a support ticket, or the reason an internal wallet was consolidated. Never place a recovery phrase, private key, passcode, API credential, full card number, or authentication code in a transaction note.

Because the note stays on that iPhone and is not part of the blockchain record, do not treat it as an off-device backup or proof that a payment occurred. The transaction ID and network receipt prove the public event; the note is your private memory aid.

## A complete reading of the example transaction

Here is how to read the public example from top to bottom without guessing:

- 

Direction: Sent. The selected wallet perspective is outgoing, so Oath prefixes the amount with a minus sign.

- 

Status: Transaction Confirmed. The Ethereum receipt reported success; later blocks continued to build confirmation depth after capture.

- 

Time: August 31, 2026 at 7:54:59 PM in the Simulator’s locale. The underlying block timestamp is public.

- 

Network: Ethereum mainnet. This determines the explorer and the meaning of the 0x addresses.

- 

Recipient: 0x42a8c9eade0235eff2b8b68f986d39ecea966180. Oath shows a compact form in the overview and the complete value in the detail sheet.

- 

Sender: 0x2394ac15081657c3289a3417adf734fad8172907. This public address authorized the transfer shown by the receipt.

- 

Transfer amount: 0.011842952936749721 ETH exactly; 0.01184295 ETH in the readable Oath presentation.

- 

Network fee: 0.000022914999093 ETH exactly; 0.00002291 ETH in Oath. It equals 21,000 gas multiplied by 1.091190433 gwei.

- 

Transaction ID: 0xcb87a10a5e90a95b860ec6eb029956ff587c08db988f08f7c62a6f07ecf182b0. This is the public key to the matching Ethereum receipt.

- 

Local note: “Verified on Ethereum mainnet - receipt checked.” This exists only in the isolated iPhone activity database and has no on-chain effect.

## When the details do not match your expectation

Pending for longer than expected. Open the transaction ID on the correct network explorer. If no receipt exists yet, the transaction may still be queued, underpriced, replaced, or awaiting provider reconciliation. Do not send the same payment again merely because the first row is pending.

Failed but a fee was charged. That can be normal on computation-based networks. The state change may revert while validators still process the attempted execution. Use the explorer receipt to inspect the failure and gas consumed.

Amount looks right but the address does not. Stop and compare the complete destination. A correct amount cannot repair a wrong network or recipient, and irreversible blockchain transfers normally cannot be recalled by Oath.

Two rows look identical. Compare their complete transaction IDs. Retries, replacements, batched actions, token-transfer logs, and self-transfers can create similar-looking summaries with distinct hashes or event indexes.

The explorer cannot find the hash. Confirm that you opened the explorer for the exact mainnet shown in Oath. A hash searched on the wrong EVM chain may return nothing even though the transaction is valid elsewhere.

The local note is missing on another device. That note was never on-chain. Use the original iPhone if the note is still needed, and keep durable records separately when accounting or compliance requires them.

## The 30-second verification checklist

- 

Open the row. Do not verify from Activity alone.

- 

Read status and timestamp. Decide whether you need more network-specific confirmation depth.

- 

Confirm the mainnet. Every address and explorer result depends on it.

- 

Check direction. Know whether the amount is leaving, arriving, swapping, or returning to your own wallet.

- 

Compare the full recipient. Tap through; never rely only on the shortened characters.

- 

Compare the sender when relevant. For received funds, make sure the expected account actually authorized the transfer.

- 

Separate amount from fee. They answer different questions and may use different assets.

- 

Open the transaction ID. Use the matching chain explorer for the public receipt and deeper execution data.

- 

Add a safe local note. Record context, never secrets.

## Questions people ask

Is a transaction hash safe to share? It does not grant spending authority, but it exposes the public transaction and can link addresses and activity. Share it only when that privacy tradeoff is acceptable. Never share a recovery phrase or private key.

Does “confirmed” mean irreversible? It means Oath received a successful terminal result. The depth and finality guarantees continue to depend on the network. High-value recipients may require additional confirmations or explicit finality.

Why is the fee smaller or larger than I expected? Network demand, transaction complexity, gas or resource use, and the fee policy selected before sending all matter. Compare the final receipt with the pre-send estimate.

Why does a token send charge ETH, SOL, TRX, or another native coin? The token is the transferred asset; the chain’s native asset generally pays for execution or network resources.

Can I edit the blockchain transaction after adding a note? No. The note is separate local metadata. It cannot change the sender, recipient, amount, fee, hash, status, or block record.

Can Oath recover a transfer sent to the wrong address? Oath cannot reverse a confirmed blockchain transfer. Contact the recipient or service if one can be identified, preserve the transaction ID, and ignore anyone who asks for your recovery phrase to “recover” it.

## One receipt, read without guesswork

A trustworthy transaction screen should not compress everything into “success” and one number. Oath keeps the public facts separate: status, time, network, direction, participants, transfer amount, fee, and transaction ID. It keeps your personal context separate too, in a note that never becomes part of the chain.

That separation is the point. The blockchain receipt answers what happened publicly. The wallet view explains how that event affects the selected account. The local note records why it mattered to you. Read all three layers, and a transaction stops being a mysterious line item. It becomes an auditable record.

Status tells you the outcome Oath received. The hash tells you which public event to verify. The note tells only you why it mattered.

## Continue learning

Before creating the receipt, use [Send Crypto Without Guesswork: From Recipient to Finality](https://oathwallet.org/articles/send-crypto-without-guesswork-recipient-to-finality). To understand the charge shown in the fee section, read [Where Crypto Network Fees Actually Go](https://oathwallet.org/articles/where-crypto-network-fees-actually-go). To retrieve the same transaction later by asset, address, or hash, continue with [Find Anything in Your Wallet: Oath Universal Search](https://oathwallet.org/articles/find-anything-wallet-oath-universal-search). For the device boundary around keys and local wallet data, see [What Never Leaves Your iPhone: Oath’s Self-Custody Security Model](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model).

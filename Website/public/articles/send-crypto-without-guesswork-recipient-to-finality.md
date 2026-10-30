# Send Crypto Without Guesswork: From Recipient to Finality

Oath Editorial · August 30, 2026

https://oathwallet.org/articles/send-crypto-without-guesswork-recipient-to-finality

Oath turns a transfer into a chain of explicit checks: exact asset, validated destination, lossless amount, visible network fee, locally bound authorization, one-shot broadcast, and exact-hash finality.

A crypto transfer can look deceptively simple: choose an asset, paste an address, enter an amount, and tap send. Underneath that short sequence are several different questions. Is this the right asset on the right mainnet? Is the destination valid for that chain? Can the account receive it? Is the quantity exact? What will the network charge? Did a node accept the signed transaction—or did the connection disappear at the worst possible moment?

Oath treats those as separate proofs. Each screen owns one decision, and the app repeats the critical network and account checks immediately before signing. The goal is not to make a blockchain transfer feel casual. It is to make every consequential detail visible before your private key authorizes it.

A good Send flow does not promise certainty where a blockchain cannot. It removes preventable ambiguity, then labels the remaining network state honestly.

## A send is a chain of explicit decisions

The production route is intentionally linear: choose the exact network asset, validate the recipient, enter an exact amount, review the transfer and fee, authorize the reviewed draft, sign locally, submit once, and monitor the resulting transaction identity. Recipient and Amount are independent screens, and Review remains the last human checkpoint before authorization.

- 

Identity proof. Oath resolves one canonical network-plus-asset variant and one validated mainnet destination.

- 

Value proof. The amount, balance, fee, reserve, and precision rules are evaluated with lossless base-10 or integer arithmetic.

- 

Intent proof. A short-lived authorization is bound to the exact wallet, account, network, recipient, amount, fee policy, and transaction options shown on Review.

- 

Network proof. The locally derived transaction identity is compared with the provider response and then monitored by exact hash until the chain reports a terminal result.

## Start with an exact asset—not a ticker

The main-wallet Send action begins with a network-aware selector. Every row is one exact asset on one mainnet. A search for a token can include its name, symbol, contract or mint, network name, or mainnet alias; a qualified result selects that exact variant without a second guessing step. A token is never resolved from a ticker or display name alone.

![Oath Send screen showing the real network-aware asset selector in the iOS Simulator](https://oathwallet.org/assets/articles/082648a67c09-01-send-asset-selection.webp)



Real Oath 2.40.12 output captured in the iOS Simulator. The screenshot is unmocked and shows the empty test wallet used for this article.

The selector covers Oath’s supported mainnets, from EVM networks and the Bitcoin family to Solana, TRON, TON, Sui, XRP Ledger, NEAR, Aptos, and Stellar. Official native artwork and exact chain-aware token identities stay attached to the transfer all the way through signing.

## A recipient is more than a plausible-looking string

Recipient Information accepts a mainnet address, a supported recipient name, a scanned QR code, or a compatible payment request. Oath applies the selected network’s complete validator; it does not approve a destination because its prefix merely looks familiar. Supported names begin cancelable resolution after a short typing debounce, and Continue remains unavailable until the current name resolves to an address that is valid for this exact network.

![Oath Recipient Information screen validating a public EIP-55 example address and warning that it is a new recipient](https://oathwallet.org/assets/articles/8caed9ec73e4-02-recipient-verified.webp)



This is a real Simulator capture using a published EIP-55 checksum example address. It is shown only to demonstrate validation; it is not a transfer recommendation or a recipient supplied by a user. No transaction was signed or broadcast.

A pasted payment request is also checked against the selected asset. A request that names another network, native coin, token contract, or mint stays on the form with a concrete mismatch instead of silently retaining an older recipient. QR scanning changes only the recipient on this screen; hidden amount, memo, token, or fee metadata cannot leak from an earlier scan into a manual transfer.

## “New recipient” is a warning, not a reputation score

After validation, Oath compares the full destination with its own accepted-send registry for this wallet and mainnet. If there is no matching app-recorded broadcast, it says that the recipient is new and asks you to check the address. If there are prior accepted sends, it can show the exact count.

That familiarity signal is deliberately narrow. It does not claim the address is trustworthy, does not inspect someone else’s history, and does not turn imported provider activity into an endorsement. On memo-capable networks, the routing detail is part of the identity: one XRP Destination Tag is not treated as familiarity with every customer behind the same exchange address.

## Some destinations need live account-state checks

Syntactic validity is not always enough. When the selected network has recipient-account rules, Oath starts a cancelable mainnet lookup on Amount and blocks Review until the live requirement is satisfied.

- 

Stellar and XRP Ledger. A missing native account must receive the current live reserve; issued assets require the destination account and matching trust line.

- 

Solana. A new native account needs the current rent-exempt minimum, while a token transfer may require the sender to fund creation of the recipient’s associated token account.

- 

NEAR. Named native recipients must exist, and NEP-141 recipients need a base account before token storage can be prepared.

- 

TRON. An inactive native destination produces an activation advisory; account creation and bandwidth remain sender-side network costs.

The same state is loaded again during final transaction preparation. Early checking improves feedback, but it never weakens the last pre-signing race check.

## Enter the amount without floating-point guesswork

The Amount screen uses Oath’s own ASCII keypad. Input accepts only digits 0–9 and one period, and the selected asset’s authoritative decimals cap the precision. Parsing, comparison, conversion to atomic units, and balance checks use exact text and integer operations—not binary floating point.

![Oath Transfer Amount screen with exact amount controls, Max, asset unit, Review Transfer, and the ASCII keypad](https://oathwallet.org/assets/articles/62a28fb07a06-03-amount-and-fee-controls.webp)



Real Simulator output from the same empty wallet. Review is correctly disabled because no positive funded amount can be prepared. The ellipsis opens the network-fee controls.

You can enter in asset units or, when a current price is available, in the selected local currency. A local-currency entry is rounded down to the asset’s supported precision and converted into one canonical asset quantity before Review. The signer never receives a fiat amount.

Max is also explicit state, not a visual shortcut. For a native coin, Oath calculates what can leave after the required network fee and any live chain reserve. For a token, Max spends the token balance while independently requiring enough native coin for gas, rent, bandwidth, storage, or another protocol cost. A scanned fixed amount that happens to equal the balance is never silently converted into Max or reduced to make room for fees.

## The fee is presented as a transaction cost

Oath begins an automatic network-fee session as soon as an asset is selected. That early quote contains network rates only; it does not send your recipient, amount, balance, or wallet identity to a fee provider. When the destination and amount exist, the estimate becomes transaction-shaped: EVM uses buffered gas estimation, Bitcoin-family networks use the current UTXO plan, Solana combines base and priority fees, TRON prepares bandwidth and energy, and every other network applies its validated protocol fee or reserve model.

![Oath Network Fee screen showing Fastest, Standard, Economy, and Custom fee choices for Ethereum](https://oathwallet.org/assets/articles/7b7dbdd60005-04-network-fee-presets.webp)



Real Simulator output opened before an amount was entered. The rows are intentionally unresolved in this capture because no complete transaction could be estimated from the empty test wallet. Oath does not invent a successful live quote.

- 

Fastest first. Fastest is the initial recommendation. Standard and Economy expose lower rates only where the protocol supplies meaningful tiers.

- 

One understandable total. The interface shows the estimated complete fee in the selected local currency, while keeping the exact native fee available on Review. It does not ask users to mentally multiply gas units, satoshis per virtual byte, or protocol-specific rates.

- 

Custom where it is meaningful. Supported networks can store exact custom base-unit values per network. Networks without a user-defined urgency market do not pretend that a custom priority price exists.

- 

No Oath transfer fee. The network fee is paid under the blockchain’s rules to its miners or validators. Oath charges no additional transfer fee.

## Review is the last human checkpoint

Final Review keeps the blockchain payment data read-only. Before authorizing, verify every line as if it were a paper instruction you were about to sign.

- 

Asset and network. Confirm the official asset and network artwork, the network name, and—on tokens—the full selectable contract or mint.

- 

Recipient. Read the full selectable destination. Do not rely on the first and last characters alone.

- 

Routing data. Verify any XRP Destination Tag, Stellar memo, payment-request label, message, or reference that will accompany the transfer.

- 

Transfer value. Confirm the exact asset quantity and its local-currency projection when pricing is available.

- 

Network fee. Confirm both the native fee quantity and its local value. Automatic fees must still be fresh before authorization.

- 

Bitcoin controls. When relevant, confirm automatic versus manual coin selection and the independent Replace-by-Fee setting.

## Authorization is bound to exactly what you reviewed

Confirm and Transfer does not hand the signer an open-ended permission. Oath issues a short-lived, single-use capability with a random nonce. It is bound to the wallet ID, exact signing account, mainnet network, and a SHA-256 digest of the reviewed draft—including recipient, amount, fee policy, prepared fee, request intent, Max state, and applicable Bitcoin controls. Change the draft and that authorization no longer matches.

If App Lock is enabled, Review requests Face ID or Touch ID when available and falls back to the normal wallet passcode route when necessary. If App Lock is disabled, Oath still creates a fresh wallet-scoped capability; it simply does not add an authentication screen the user did not configure. Capabilities stay in memory, expire, and are never stored in the transaction database.

## Signing stays local—and proves the account again

At signing time, Oath reloads the selected wallet secret from the protected Keychain vault. A recovery-phrase wallet re-derives the requested account, including its exact BIP-39 passphrase when one exists; an imported private-key wallet reloads its scoped key. The derived public address must match the persisted source account before the key can sign.

The private key never travels to the RPC provider. Oath constructs and signs the chain-native transaction locally, then derives the canonical transaction identity from those exact signed bytes before submission. That local hash or signature becomes evidence the app can compare with the network response.

## Broadcast once; classify the outcome honestly

Read-only preparation can use bounded provider failover. Signed submission is different. Oath chooses one route and does not replay the payload through another provider after an ambiguous timeout, transport failure, cancellation, malformed response, or hash mismatch. The first node may already have accepted it, and a “helpful” retry could create a duplicate payment.

- 

Definitive rejection. The provider proves the transaction was not accepted. The screen shows the sanitized, actionable reason and can offer a fresh attempt through Review and a new authorization.

- 

Accepted or already known. The node accepts the transaction or proves that the identical signed payload is already in its pool or chain. Oath keeps the locally derived identity and begins status monitoring.

- 

Outcome unknown. The app has transaction evidence but cannot prove whether the node accepted it. Oath shows the exact local hash, tells you to check activity or a block explorer, and intentionally withholds Retry.

- 

Executed failure. The network included or executed the transaction but reported failure. The hash is retained, fees may have been charged, and the consumed nonce or sequence makes blind retry unsafe.

## Submitted is not the same as final

As soon as Oath has an accepted receipt—or an unknown outcome with a locally derived hash—the Transaction screen starts an exact-hash status monitor. It reads every four seconds while the screen is open and stops only at a confirmed or failed terminal result. A temporary provider or decoding problem becomes a warning, not a fictional failure.

Each chain keeps its own finality definition. EVM networks require the exact transaction receipt. Bitcoin-family networks require the transaction in the sender’s script history at a positive block height. Solana checks signature status with transaction-history search. TRON waits for its solidity-node result and block. TON verifies the external-message trace and action outcomes. Sui, XRP Ledger, NEAR, Aptos, and Stellar resolve their native exact transaction identity and terminal execution state. “Not found yet” remains pending.

When a terminal state arrives, Oath updates only the matching local record: same wallet account, same mainnet, same normalized hash. A local database write failure is shown separately and never changes what the blockchain actually reported.

## The receipt remains useful after submission

The Transaction screen keeps Status first, then the exact asset, recipient, transaction ID, amount, and network fee. The complete recipient or transaction ID opens in its own selectable detail sheet, and the transaction ID can be copied, shared, or opened in the correct mainnet explorer when supported.

After network acceptance, you can add a local note. Notes live in Oath’s database and are never inserted into transaction calldata, a Solana memo, an XRP tag, or another on-chain field. A scoped wallet refresh begins shortly after broadcast so balances and activity can reconcile even if you close the Send sheet.

## A practical no-guesswork sending ritual

- 

Choose the exact asset and mainnet variant. For tokens, verify the contract or mint when the name exists on more than one chain.

- 

Use Paste or Scan QR when possible, then compare the full destination with the source you trust. Treat every new-recipient warning as a reason to pause.

- 

Enter the quantity in asset units or local currency and confirm the exact asset amount Oath will sign. Use Max only when you mean to spend the calculated maximum.

- 

Open Network Fee when speed or custom policy matters. Read the total as a network cost, not as an Oath charge.

- 

On Review, verify the asset, network, contract or mint, full recipient, routing memo or tag, amount, and fee—once, slowly.

- 

Authorize only while that Review still matches your intention. Oath binds the resulting capability to that exact draft.

- 

After submission, keep the transaction ID. If Oath says the outcome is unknown, check that exact hash before doing anything else and do not rebuild the payment blindly.

- 

Wait for the chain-specific confirmed state when finality matters. A mempool or submitted state is progress, not completion.

## What the status language is telling you

- 

New recipient. Oath has no matching accepted app send from this wallet on this mainnet. Verify the full destination and routing detail.

- 

Submitted. A provider accepted the signed transaction or proved the identical payload was already known. Confirmation is still pending.

- 

Confirmed. The network-specific finality monitor found the exact transaction and verified its successful terminal state.

- 

Status unconfirmed. Oath has transaction evidence but cannot currently prove acceptance or finality. Check the exact hash; do not assume failure and resend.

- 

Not sent. The failure was proven before acceptance. A retry, when offered, returns through Review and obtains a fresh authorization.

- 

Execution failed. The transaction reached the network but did not complete successfully. Keep the hash and inspect the chain result before deciding what comes next.

## Confidence comes from preserving distinctions

A wallet cannot make an irreversible network feel reversible. What it can do is preserve the distinctions that matter: a ticker versus an exact asset, a plausible address versus a validated destination, a decimal display versus an atomic amount, an estimate versus a prepared fee, authentication versus signing authority, submission versus acceptance, and acceptance versus finality.

That is the Oath Send flow. It makes the human decision legible, binds the key to that decision, submits the signed transaction once, and follows the exact result without pretending uncertainty is failure.

Verify the destination. Bind the intent. Broadcast once. Follow the hash.

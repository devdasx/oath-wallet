# Where Crypto Network Fees Actually Go

Oath Editorial · August 30, 2026

https://oathwallet.org/articles/where-crypto-network-fees-actually-go

A network fee is not one universal charge. Follow it through miner rewards, validator tips, burns, L1 settlement, storage funds, and protocol pools—and see exactly what Oath does with none of it.

You press Send. Your wallet shows a network fee. A little later, the recipient receives the transfer—and some extra amount has left your balance. The natural question is simple: who got it?

There is no single answer. On one chain, the fee becomes miner revenue. On another, one part rewards a validator while another part is permanently destroyed. A rollup can divide the cost between executing your transaction and publishing data to a different chain. Some protocols route fees into storage funds or locked pools. Others let a contract or application sponsor part of the resources.

The label “network fee” hides all of that machinery. This guide opens the machine.

Oath does not receive any part of the network fee and adds no transfer surcharge. The destination and accounting are determined by the blockchain protocol.

## First: a fee is a price for scarce network work

A blockchain does not merely move a number from one screen to another. Independent computers must validate the transaction, order it, execute any program logic, store or commit the result, distribute it across the network, and eventually make it final. Those operations consume scarce block space, computation, bandwidth, storage, or settlement capacity.

The fee is the protocol’s method for pricing that scarcity and discouraging unlimited spam. But protocols disagree about what should happen to the value after it is collected. That design choice affects validator incentives, token supply, storage economics, and even how an app should explain the estimate.

## What Oath estimates—and what the chain charges

A wallet can estimate the cost before signing, but it cannot rewrite the protocol. Oath first obtains rate information without sending a recipient, transfer amount, balance, or wallet identity to the fee quote provider. Once the destination and amount exist, the estimate becomes transaction-shaped: it reflects the actual network, asset, recipient, amount, and chain-specific work that the unsigned transfer is expected to require.

![Real Oath Transfer Amount screen in the iOS Simulator with the Network Fee menu available from the toolbar](https://oathwallet.org/assets/articles/0a8a64ce268f-01-amount-network-fee-entry.webp)



Real Oath 2.40.12 output captured in the iOS Simulator. The wallet is intentionally empty, Review is disabled, and no transaction was signed or broadcast. The ellipsis opens Network Fee.

The important distinction is this: a rate is not always the complete fee. Bitcoin needs a transaction size and UTXO plan. Ethereum needs a gas limit plus fee-per-gas rules. Solana combines a base fee with any prioritization fee. TRON may consume staked Bandwidth and Energy before burning TRX. A rollup may add an L1 data or security component to its own execution charge. Oath prepares the total using the builder for the selected mainnet instead of multiplying every chain by one generic formula.

## Speed choices are protocol-aware

Fastest, Standard, and Economy are understandable intentions—not promises that every blockchain has the same auction. Oath exposes multiple tiers where rates can meaningfully influence inclusion. Where a protocol has no user-defined urgency market, the app does not invent one. Custom values are kept separately by network so a preference on one chain cannot silently become a dangerous value on another.

![Real Oath Network Fee screen in the iOS Simulator showing Fastest, Standard, Economy, and Custom choices for Ethereum](https://oathwallet.org/assets/articles/c1d1f70fe6c9-02-ethereum-network-fee-presets.webp)



A real Simulator capture before a funded amount existed. The dashes are deliberate: Oath has no complete transaction to price, so it does not display a fictional fee.

On the final Review screen, Oath shows the prepared native fee and its local-currency value when pricing is available. That reviewed fee policy becomes part of the exact draft authorized for signing. If the draft changes, the earlier authorization no longer matches.

## The five places a network fee can go

- 

Block producers. Miners or validators receive some or all of the fee as compensation for ordering, executing, and securing transactions.

- 

The burn. Some protocols destroy a portion—or all—of the charged asset, permanently removing it from circulating supply.

- 

Another settlement layer. Rollups can pay a base layer for data availability or security in addition to charging for local execution.

- 

A protocol fund or pool. Storage funds, locked fee pools, and resource accounts can keep value inside the protocol for a defined long-term purpose.

- 

Contracts or resource sponsors. Some networks share execution economics with contracts, or allow developers to stake resources so users pay less directly.

Many networks use more than one destination at once. Follow the examples below and the same word—fee—will describe very different routes.

## Bitcoin: the miner receives the difference

A Bitcoin transaction spends existing outputs and creates new outputs. Its fee is not a separate field paid to a fee address. It is the difference between the total input value and the total output value. When a miner includes the transaction, that unassigned value becomes available through the block’s coinbase transaction. The [Bitcoin developer guide](https://developer.bitcoin.org/devguide/transactions.html) describes this accounting directly.

This is why transaction size matters more than the number of bitcoin being sent. A small-value transfer that must combine many UTXOs can consume more virtual bytes than a large-value transfer using one clean input. The miner is being paid for block space, not a percentage of your payment.

## Ethereum: base fee burned, priority fee rewarded

An Ethereum fee is gas used multiplied by the effective price per unit of gas. Under Ethereum’s current fee market, the mandatory base fee is burned. The optional priority fee—the tip used to make inclusion more attractive—goes to the validator. The network’s [official gas documentation](https://ethereum.org/en/developers/docs/gas/) also explains why an executed transaction can consume gas even if the call ultimately fails: validators still performed the computation.

The sender can cap the maximum fee per gas, but the chain charges only the effective amount permitted by the base fee, tip, gas limit, and actual gas consumed. Unused gas is not a bonus handed to the validator. A wallet therefore needs both a realistic gas limit and current pricing; one without the other is not a complete estimate.

## Base and other rollups: execution plus settlement

A rollup transaction can have two economic layers. On Base, the total includes an L2 execution fee and an L1 security fee related to publishing transaction data for Ethereum settlement. Base’s [network-fee documentation](https://docs.base.org/base-chain/network-information/network-fees) explains both components.

The destination is also different from Ethereum mainnet. In the OP Stack design used by Base, priority fees, L2 base fees, and L1-cost fees are accounted through separate protocol fee vaults rather than treating the L2 base fee as Ethereum’s mainnet burn. This is the clearest reason not to say “every EVM fee is gas burned.” The transaction format may feel familiar while the fee route is not.

## Solana: base fee split, priority fee to the validator

Solana combines a base transaction fee with an optional prioritization fee based on the requested compute-unit limit and compute-unit price. According to Solana’s [official fee documentation](https://solana.com/docs/core/fees), half of the base fee is burned and half goes to the validator; the prioritization fee goes to the validator.

The compute-unit limit matters. Setting it far above the transaction’s needs can overpay because the priority calculation uses the requested limit, not merely the units ultimately consumed. The base signature fee is still charged when a transaction is processed and fails, because the network verified and scheduled real work.

## XRP Ledger: the transaction cost is destroyed

On the XRP Ledger, the transaction cost is not paid to a validator or company. It is irrevocably destroyed. The [XRPL transaction-cost guide](https://xrpl.org/docs/concepts/transactions/transaction-cost) describes the cost as an anti-spam mechanism and explains that open-ledger demand can increase the amount required for a transaction to be considered.

That means “who receives the fee?” has a surprisingly literal answer here: nobody. It leaves the sender’s balance and ceases to exist.

## TRON: resources first, TRX burn when resources run short

TRON measures ordinary transaction bytes with Bandwidth and smart-contract execution with Energy. Accounts can obtain those resources through staking or delegation. If the available allowance is insufficient, the protocol deducts and burns TRX for the missing resources. The charging order is documented in TRON’s [Bandwidth and Energy guide](https://developers.tron.network/docs/bandwidth-and-energy).

A contract deployer can also stake and share Energy for calls to that contract. Two users performing similar actions may therefore pay different direct amounts depending on account resources and the contract’s sponsorship settings. A fee estimator has to inspect the resource model, not assume a simple auction price.

## Sui: computation rewards and a storage fund

Sui separates computation and storage economics. Computation gas supports validator rewards. Storage fees flow into the storage fund, whose design compensates future validators for the long-term cost of maintaining on-chain data. When data is deleted, the protocol can return a storage rebate, less the non-refundable portion defined by the protocol. See Sui’s [tokenomics paper](https://docs.sui.io/paper/tokenomics.pdf) for the full model.

This is a different mental model from paying once for a line in a block. Part of the charge is about who bears the storage obligation later.

## NEAR: burn plus a contract reward

NEAR prices execution through deterministic gas rules rather than a priority-fee bidding market. Its [official gas documentation](https://docs.near.org/protocol/transactions/gas) explains that a portion of gas burned during contract execution is credited to the contract account, while the remainder is burned. The documented contract reward is 30 percent of the gas burned during execution.

For users, that means a contract call and a simple transfer do not share exactly the same destination story. It also means paying more cannot buy a faster priority lane in the same way it can on a congestion-priced auction.

## Stellar: fees enter a locked protocol pool

Stellar’s classic transactions pay an inclusion fee, while Soroban smart-contract transactions also account for resource fees. The network’s [fees and resource metering guide](https://developers.stellar.org/docs/learn/fundamentals/fees-resource-limits-metering) states that collected network fees go into a locked account and are not paid out or otherwise used. Stellar tracks this as a protocol fee pool outside circulating supply.

So Stellar’s route is neither an immediate validator reward nor exactly the same burn mechanism used elsewhere. The value becomes inaccessible under the protocol’s accounting.

## TON: storage, gas, routing, and message forwarding

TON’s fee is a bundle of work performed across transaction phases. It can include storage fees, computation gas, action fees, and forwarding fees for outbound messages. The [TON transaction-phase documentation](https://docs.ton.org/foundations/phases) shows the order in which those components are calculated and deducted.

A TON transfer is message-driven, so forwarding the message tree can matter as much as executing the first account. The protocol can also reach a partial execution state in which earlier phases consumed resources before a later action failed.

## Why a failed transaction can still cost money

“Failed” can describe different moments. A transaction rejected locally before signing costs nothing on-chain. A node that refuses an invalid payload before accepting it may also leave the balance untouched. But once a valid transaction is included or executed, the network may have verified signatures, consumed a nonce or sequence, run program instructions, read and written state, or forwarded messages—even if the requested outcome did not complete.

Protocols charge for that work because otherwise anyone could force validators to execute unlimited failing programs for free. Ethereum and Solana explicitly charge processed failures; other networks apply their own phase and resource rules. The safe interpretation is not “failure always costs” or “failure never costs.” It is: check whether the chain accepted and executed the exact transaction.

## Why the number changes between two sends

- 

Demand for block space. Congestion raises auction-based rates and can change which urgency tier is likely to be included.

- 

Transaction size. More Bitcoin inputs, longer scripts, additional signatures, or larger L2 data payloads increase the bytes that must be committed.

- 

Computation. A token transfer or contract interaction usually executes more logic than a native transfer.

- 

State and storage. Creating an account, token account, trust line, storage record, or long-lived object can add reserves, rent, or storage costs.

- 

Settlement-layer conditions. A rollup’s L1 data component can move even if local L2 execution demand is unchanged.

- 

Account resources. TRON Bandwidth and Energy, Sui storage rebates, and protocol-specific balances can change the net amount paid directly.

- 

Fee policy. Fastest, Standard, Economy, or a custom limit can change the ceiling or priority component where the network supports it.

## Honest estimation includes honest failure states

A fee number should come with evidence. If current price data is unavailable, a local-currency conversion is not trustworthy. If the balance cannot be verified, the app cannot honestly promise that a custom fee is spendable. Oath preserves the concrete reason and blocks Apply instead of replacing it with a generic connection message or a made-up value.

![Real Oath Custom Network Fee screen explicitly reporting unavailable live price and balance verification instead of inventing a quote](https://oathwallet.org/assets/articles/0b2c19456a0e-03-custom-network-fee.webp)



Real Simulator output from the intentionally empty article wallet. Current local pricing and fee-balance verification were unavailable, so Oath exposed both conditions and kept Apply disabled. This is a production failure state, not a mockup.

Automatic fee requests are bounded, and a provider error stays distinguishable from a successful live quote. Where Oath has a built-in protocol fallback, it is labeled as such rather than presented as a fresh network observation.

## How to read Oath’s fee screen

- 

Confirm the network. The fee model belongs to the selected mainnet. A similarly named token on another chain is a different transaction.

- 

Treat the preset as an intention. Fastest asks for stronger inclusion economics where supported; Economy accepts a slower target. Neither can guarantee a block time.

- 

Read the complete amount. Oath presents an estimated total transaction fee in the selected local currency and preserves the exact native fee for Review.

- 

Look for additional chain costs. Account activation, rent, storage, associated token accounts, reserves, or L1 data can be required even when they are not a validator tip.

- 

Stop on unresolved data. A dash or concrete validation message means the evidence is incomplete. It is not a zero-fee promise.

- 

Verify again on Review. The prepared fee is tied to the actual recipient, amount, and transaction draft immediately before authorization.

## Pay less without creating a riskier send

- 

If the transfer is not urgent, wait for lower congestion or select a slower preset where the network supports meaningful fee tiers.

- 

Keep enough of the network’s native asset for fees. A token balance cannot usually pay the underlying gas unless the protocol and transaction explicitly support sponsorship.

- 

On Bitcoin, understand that many small UTXOs create a larger transaction. Consolidation can reduce a future transaction’s size, but doing it now is itself an on-chain transaction and should be considered only when current fees and privacy tradeoffs make sense.

- 

Avoid repeatedly submitting a contract call that already failed. Read the exact execution reason and transaction hash before rebuilding it.

- 

Do not confuse a normal transfer fee with a bridge, swap, withdrawal, or application charge. Those workflows can include separate protocol or service economics beyond sending one asset on one network.

- 

Never lower a custom ceiling blindly. An underpriced transaction may remain pending, and replacement rules differ by chain.

## The fee is not a mystery charge

The cleanest way to understand a network fee is to ask three separate questions: what work is being priced, how is the amount calculated, and where does the collected value go? Bitcoin, Ethereum, Solana, Base, XRP Ledger, TRON, Sui, NEAR, Stellar, and TON answer those questions differently because they are different economic systems—not skins over one universal payment rail.

Oath’s role is narrower and more useful: build the exact mainnet transaction, obtain and validate the relevant rates and resources, show the prepared cost before authorization, sign locally, and report the chain’s result. The protocol receives, routes, burns, or locks the fee. Oath receives none of it.

The fee is the network’s price for doing the exact work you asked it to do. The wallet’s job is to make that price—and its uncertainty—visible before you sign.

# Oath 3.5.5: A Better Feel for Every Transfer

Oath Editorial · September 14, 2026

https://oathwallet.org/articles/oath-3-5-5-slide-to-send-transaction-activity

Meet Slide to Send, clearer transaction activity, better Max fee handling, and simpler transaction details. A complete guide with real app screenshots and a hands-on video.

Sending a transaction has a few moments that deserve your full attention: the address, the amount, the fee, and the final decision to let it go. Everything around those moments should be easy to follow.

Oath 3.5.5 brings a new Slide to Send control, a clearer way to follow transactions, and more reliable fee handling when you use Max. It also tidies up the details you read afterward—and keeps ordinary screens where you left them when you return to the app.

This guide covers the changes across the 3.5.5 release, including the latest build, 59. The screenshots and video use Oath’s actual interface in iOS Simulator with demonstration balances, prices, addresses, and transaction results. No funds were signed or sent. The video’s confirmation timing is simulated; it is not a claim about network speed.

## Slide to Send: the final decision stays under your thumb

The last action on Review Transfer is now a slider. Three animated arrows and a soft shimmer show the direction to move. The control follows the language of the interface: left to right in English, right to left in Arabic and other right-to-left languages.

There is a useful distinction between reaching the end and letting go. Oath sends only when you release after completing at least 90% of the slide. Keeping your finger down at the end does not send the transaction. You can still move back below the threshold and release to cancel the gesture.

As you slide, the existing blue capsule becomes more pronounced. Light, stepped haptic feedback helps you feel your progress, with a softer approach to the end. The return motion follows the distance you have moved, so a short attempt and an almost-complete slide do not snap back in the same way. On supported devices, these small details make the control feel like something you move, rather than a button you happen to drag.

![Review Transfer in Oath 3.5.5 with a blue Slide to Send control.](https://oathwallet.org/assets/articles/14115bc76ecb-review-transfer.webp)



Review Transfer with sample Dogecoin amounts and a demonstration recipient. The screen is a real Simulator capture; values are illustrative.

### How to use it

- 

Choose the asset and recipient, then enter the amount you want to send.

- 

On Review Transfer, check the network, recipient, amount, and fee. If you changed transaction options, review those too.

- 

Place your finger on the circular handle and slide in the direction of the arrows.

- 

Change your mind? Move back below 90% before lifting your finger, or release an incomplete slide. Nothing is submitted by that gesture.

- 

Ready? Complete the slide and lift your finger. A short animated checkmark appears in the handle before the review sheet closes.

That first checkmark acknowledges your completed gesture. It is not blockchain confirmation. The transaction still has to be submitted and accepted by the network; its progress appears in the activity capsule.[Watch the video](https://oathwallet.org/assets/articles/054e319a27e8-slide-to-send.mp4)

Video: the real Oath slider, recorded in Simulator with demonstration data. An incomplete slide returns; a completed slide waits for release. Submission and confirmation are simulated. No real funds were sent.

### When the fee is still loading

Before the transfer is ready, the slider explains what is happening with “Getting network fee…” and a native loading indicator in its handle. Once the fee is available and the transfer passes its checks, the control changes smoothly into its enabled state.

Returning to an unchanged transfer no longer unnecessarily starts the whole loading experience again. A usable fee presentation stays available while the app refreshes what it needs. Editing the transaction can still require new calculations, and network conditions can change. Always check the reviewed amount and fee before sending.

## One place to follow a transaction

After submission begins, a capsule appears near the top of Home. The asset’s logo stays visible, with a small badge that changes as the transaction progresses. You no longer have to interpret the same “sent to network” message at every stage.

- 

Sending… means Oath is working on submission. The badge is a loading indicator.

- 

Transaction Sent means the submission was accepted. A dot marks this stage; it is not a confirmation checkmark.

- 

Confirming… means the transaction is still waiting for the network’s confirmation. The badge shows a loading indicator.

- 

Transaction Confirmed means the app has received confirmation evidence. The badge becomes a green checkmark.

- 

Transaction Failed shows a danger badge. Open the transaction to read the specific result and any next step.

A connection problem or a temporarily unavailable result is not proof that a transaction failed. If the outcome is uncertain, Oath keeps that distinction rather than presenting an unverified success or failure.

### A capsule that gets out of the way

Once you have seen a Confirming or Confirmed capsule, it dismisses itself after three seconds. That countdown continues if you move to another screen; you do not have to return to Home and watch it again. You can also swipe it upward to hide it yourself. Sent and Failed states remain available until dismissed rather than disappearing on the same automatic timer.

If a transaction confirms while its capsule is still visible, the existing capsule changes to Confirmed. If the capsule has already gone away, the confirmation can appear again as a new update for that same transaction, then dismiss after three seconds. A later failure can also bring the capsule back so the result is not missed.

Swiping away the capsule only hides the notification. It does not cancel a transaction that has already been submitted.

### Several transfers? Open the bell

The bell beside the wallet selector appears when there is relevant transaction activity. Its number tells you how many items need attention. Tap it to open Activity, where you can follow pending incoming and outgoing transactions and relevant failures, then open an individual transaction for details.

The list keeps the information compact: the asset logo and status badge, the current status, the amount with its ticker, and a disclosure arrow. Repeated coin and network names have been removed from these rows. It uses the native navigation bar and close control, with the same glass presentation as the activity surface.

![Oath Activity showing a confirming transaction, amount, status badge, and disclosure arrow.](https://oathwallet.org/assets/articles/a16131e41737-activity.webp)



Activity opens from the bell and keeps each transfer compact. This is a simulated pending transaction in the real app interface.

The small capsule continues to show one transaction at a time. The bell is the place to check the wider picture, especially if you send more than one transfer before the earlier ones confirm.

## Max now makes proper room for the fee

When you send a network’s native coin, the amount you can transfer must leave enough to pay that network’s costs. Choosing Max should account for that before you reach the final slide.

Version 3.5.5 improves this calculation, including a TRON issue where a Max transfer could fail with an insufficient-balance message even though the wallet had TRX. The available balance was being committed to the transfer before all applicable costs were properly reserved. Oath now makes room for the required costs before building the native TRX transfer.

For TRON, those costs can include bandwidth and, when applicable, recipient-account activation. Your resources, the recipient, and current network rules affect the result. A custom fee must also cover the required cost; setting it too low cannot make the network accept an underfunded transfer.

![TRON Review Transfer showing a demonstration amount and network fee.](https://oathwallet.org/assets/articles/ebdbf3e134c1-tron-review.webp)



Illustrative TRON review: 98.9 TRX for the recipient and a 1.1 TRX fee from a 100 TRX demo balance. Actual fees vary.

Here is an illustrative example: if a wallet has 100 TRX and the required fee is 1.1 TRX, the transferable amount is 98.9 TRX. Those are demonstration numbers, not a fixed TRON fee. On networks that require an account reserve or a minimum remaining balance, that requirement must be retained too. Max means the maximum spendable amount, which is not always the entire displayed balance.

### Native coins and tokens work differently

For a native-coin transfer, Max accounts for the fee in that same coin. For a token transfer, you can send the token balance, but the network fee still needs to be funded separately with the native coin on that network.

For example, sending a TRC-20 token requires enough TRX for its network fee. Holding a large token balance does not by itself cover that fee. Oath checks the native fee balance; it does not automatically sell tokens or subtract a token quantity as a substitute for native gas.

To use Max, choose the correct asset and network, enter the recipient, tap Max on the amount screen, and review the resulting amount and Network Fee before completing the slide. If a fee or reserve leaves no spendable amount, add the required funds or choose a smaller transfer when appropriate.

## Bitcoin-family change: no more avoidable dust output

Bitcoin, Bitcoin Cash, Litecoin, and Dogecoin use unspent transaction outputs, or UTXOs. A transfer spends one or more outputs and usually returns the remainder to your wallet as change. That change is separate from the amount sent to the recipient.

Sometimes the leftover change is too small to create a valid, relayable output. This is called dust. A wallet can have enough total funds and still build a transaction the network rejects if it tries to create that tiny change output.

In 3.5.5, change below the applicable dust threshold is added to the network fee instead of being emitted as a dust UTXO. The calculation is handled consistently through review and transaction construction for the supported Bitcoin-family send paths.

This is particularly useful when spending several small outputs or sending almost everything. It removes an avoidable rejection without leaving a tiny output behind. The dust threshold depends on the network and output type, so there is no single dollar amount that applies everywhere.

The rule applies to the leftover change—not to the recipient’s payment. A recipient output that is itself below the network’s minimum still needs to be corrected. Always review the fee, including any small remainder absorbed into it. Coin Control remains available if you want to choose which UTXOs the transaction spends.

For more context on address types, derivation indexes, and Coin Control, see our [complete Bitcoin settings guide](https://oathwallet.org/articles/bitcoin-settings-oath-address-types-indexes-complete-guide).

## Confirmation and balance updates that follow the transfer

A transaction can be confirmed on-chain while a wallet is still showing older information. This release improves the checks behind pending transactions across the app’s supported networks, including the Bitcoin Cash path that could leave a completed transfer looking pending.

After a send, Oath begins refreshing the affected network’s balance after approximately two seconds and follows up as the transaction’s result becomes available. Failed or rejected attempts also prompt a balance refresh. Pending transaction tracking can resume when you reopen the app.

That two-second point is the start of a balance check, not a promise that a blockchain or its data provider will have updated within two seconds. A balance that has not changed does not prove a send failed: the provider may be behind, and a transfer between your own addresses may produce a different balance change from a payment to someone else. Transaction status and balance evidence need to be considered together.

The practical improvement is less waiting for Oath to catch up after new information becomes available. It does not make blocks arrive faster, change a network’s finality rules, or allow unlimited polling while iOS has suspended the app.

## Transaction details, with less repetition

The transaction screen has been simplified around the information you actually need to inspect. “Confirmation Pending” is now the shorter “Pending.” “Blockchain Network” becomes “Network,” and “Transfer Amount” becomes “Amount.” The network appears once in the overview rather than being repeated in the transfer summary.

The Transfer Summary now brings Amount and Network Fee together. The separate Value and Fee in US Dollar rows are gone. Both summary values start in your selected local currency; tap an available value to switch it to the relevant cryptocurrency unit, then tap again to switch back.

![Oath transaction details with confirmed status and local-currency Amount and Network Fee.](https://oathwallet.org/assets/articles/273186040128-transaction-details.webp)



The simplified Transfer Summary brings Amount and Network Fee together. All transaction data shown here is demonstration data.

This keeps the summary short without taking away the precise coin amount. For a token transfer, remember that the amount and fee may be denominated in different assets: the token you sent and the native coin that paid the fee.

![The same transaction details after tapping Amount to display 25 DOGE.](https://oathwallet.org/assets/articles/153a529d4472-transaction-details-units.webp)



Tap Amount to switch the same value from local currency to cryptocurrency units. The fee has its own display toggle.

Interactive values now use the same neutral text treatment as the other fields. A disclosure arrow is reserved for a row that opens another screen or sheet. Tapping an amount to change its display does not need a navigation arrow because you stay on the same screen.

The transaction hash, sender, recipient, status, and local notes are still there when you need them. Notes remain on your iPhone and are not written into the blockchain transaction.

## Come back to the screen you left

If you leave Oath while an ordinary transaction sheet is open, returning after a few minutes should not unexpectedly close it. Version 3.5.5 preserves that presentation while the app remains in memory, so you can continue reading where you stopped.

Screens that reveal sensitive wallet material are treated differently. A recovery phrase, private key, or other secret-reveal screen closes after about 20 seconds away. Your existing App Lock settings continue to apply; this change does not remove them.

As with other iOS apps, force-quitting the app or having iOS terminate it is different from switching away and returning. This improvement concerns resuming the running app, not a promise to restore every open sheet after a fresh launch.

## A quieter Home and a tidier Receive screen

Home opens without the previous fade-and-scale entrance. The bottom settings control now uses a gear icon, making its purpose easier to recognize next to search.

Receive’s network filters have also been refined. The spacing beneath the title is tighter, and the chips fit their text and circular network artwork more naturally. Tap a network to narrow the asset list, or choose All to see the broader selection.

![Oath Receive asset selector with network filter chips beneath the title.](https://oathwallet.org/assets/articles/5e341905567f-receive.webp)



Receive uses content-sized network chips and tighter spacing beneath the navigation title. Assets and balances are samples.

Temporary refresh problems also receive better handling. Existing wallet content can remain visible instead of being interrupted by the technical wallet-refresh alert that exposed a timeout code. A temporary inability to refresh is not the same as losing your wallet or your funds.

Account-activation guidance is more selective too. On networks with a genuine activation or funding requirement, the amount screen surfaces the relevant shortfall when it matters. It avoids showing an unnecessary “not active” warning when the entered amount already satisfies the applicable requirement.

## A few more fixes worth knowing about

- 

Backup and private-key messages are clearer, with more specific wording for the material or action involved.

- 

Import handles rejected phrase entries more cleanly when you choose to try a different phrase.

- 

The send activity flow includes fixes for a background queue crash and for capsules that could linger after you had already seen them.

- 

Slider movement, direction, and feedback have been refined for both left-to-right and right-to-left interfaces, including a smoother return while you move your finger back.

The common thread is straightforward: give you a clearer decision before a transfer, a clearer result afterward, and fewer interruptions in between.

## Getting 3.5.5

Oath 3.5.5 is available on the [App Store](https://apps.apple.com/app/id6780187283). Open the listing on your iPhone or iPad and choose Update if you already have Oath installed.

Once installed, the in-app Version History contains the notes for your exact version and build. Start with a transfer you can review carefully: check the recipient, inspect the fee, try moving the slider and returning it, and only complete and release it when you are ready to submit.

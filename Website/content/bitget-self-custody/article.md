# Your Crypto, Their Permission: The $388 Million Bitget Wake-Up Call

*By Oath Wallet · September 28, 2026*

An exchange can promise to replace stolen money. It cannot give you back the moment you needed to move it.

That distinction is easy to overlook when markets are calm. Your balance appears on a screen. You can buy, sell, and watch its value change. The experience feels like possession. Only when withdrawals stop does the underlying arrangement become visible: someone else has the authority to release your assets.

Bitget’s September 24 security breach has made that arrangement painfully concrete. The exchange initially estimated the loss at $351.6 million, then revised it to **$387.5 million** after identifying additional affected transfers. Its latest public account rounds the figure to approximately **$388 million**. These are estimates of assets taken from exchange infrastructure—not evidence that customers individually suffered equivalent, unreimbursed losses. [Bitget’s September 25 update](https://www.bitget.com/support/articles/12560603896108); [updated incident account](https://www.bitget.com/amp/academy/bitget-security-incident-what-happened-timeline-impact-response).

The distinction matters. So does the fact that customers could not withdraw while the exchange repaired its systems.

We build Oath Wallet because we believe people should be able to hold and use their crypto without relying on an exchange’s permission. But the case for self-custody deserves more than a slogan, and readers deserve more than a frightening headline. It requires a careful account of what failed, what an exchange can actually promise, and which responsibilities move to you when you take control of your keys.

## What actually happened at Bitget

The incident affected Bitget’s centralized exchange. **Bitget Wallet, its separate non-custodial product, was not affected, according to Bitget.** Confusing those products would obscure the very distinction this story illustrates. [Bitget’s incident account](https://www.bitget.com/amp/academy/bitget-security-incident-what-happened-timeline-impact-response).

The exchange’s September 25 update reported unauthorized transfers across several networks, including assets on Ethereum and other EVM chains, XRP Ledger, Zcash, and TRON. The upward revision from $351.6 million to $387.5 million reflected a fuller accounting, including Zcash and TRON transfers omitted initially. Bitget said the revision did not indicate a second attack or further transfers after containment. It also announced recovery bounties for qualifying assistance in freezing or recovering funds. [Official fund-tracing and recovery update](https://www.bitget.com/support/articles/12560603896108).

### The attackers did not necessarily need to steal the keys

Bitget’s current explanation is preliminary: an attacker may have exploited a third-party security product to obtain privileged internal credentials, then used them to issue fraudulent withdrawal commands. The exchange says private-key compromise has been ruled out in its investigation to date, and its cold wallets were unaffected. Mandiant and SlowMist are supporting the continuing investigation. [Bitget’s incident account](https://www.bitget.com/amp/academy/bitget-security-incident-what-happened-timeline-impact-response).

Blockchain investigator TRM Labs described the reported failure as manipulation of the information used to authorize transfers. Its analysis also traced the dispersal of stolen funds and routes through cross-chain services. TRM identified links suggesting North Korean involvement but stopped short of definitive attribution. That uncertainty belongs in any responsible account of the breach. [TRM Labs’ analysis](https://www.trmlabs.com/resources/blog/bitget-loses-usd-3516-million-in-hot-wallet-breach-in-likely-north-korea-attack).

The security lesson is broader than the identity of the attacker. A private key can remain secret while the machinery surrounding it authorizes a disastrous transaction. A signing system answers a cryptographic question: was this transaction approved by the required key? It does not, by itself, establish that the human intention behind the transaction was honest or correctly understood.

For an exchange customer, this creates a difficult boundary. You can secure your password, protect your email, and use strong authentication. You cannot personally inspect every privileged credential, third-party dependency, withdrawal rule, or internal approval process at the exchange. Your account security and the institution’s custody security are related, but they are different systems.

### The pause exposed who controlled access

Bitget’s updated chronology places the first unauthorized transfers at 18:31 UTC on September 24. It says reconciliation detected a discrepancy and automatically blocked withdrawals at 19:05; withdrawal and signing services were shut down at 21:44. These are the company’s reported timings, not our independent forensic reconstruction. [Updated incident timeline](https://www.bitget.com/amp/academy/bitget-security-incident-what-happened-timeline-impact-response).

Pausing a compromised withdrawal system can be the responsible response. Continuing to operate it could expose more assets. The problem for customers is that the same measure needed to protect the collective pool also prevents an individual from leaving it.

That is a structural limitation of custodial protection. A platform can have a good reason to suspend withdrawals, yet the customer still loses the ability to act. There need be no dishonesty, insolvency, or malicious intent for this loss of control to occur.

### The recovery is part of the story, too

Bitget says customer balances remain unaffected and its Protection Fund covers the incident’s financial impact. Its published schedule proposed reopening BTC withdrawals on September 28, ETH on September 29, USDT on September 30, and remaining supported tokens, fiat withdrawals, and P2P services on October 2, each at 08:00 UTC. Those later dates remain a schedule, not completed milestones as of this article. [Bitget’s withdrawal announcement](https://www.bitget.com/support/articles/12560603896110).

On September 28, The Block reported that Bitget had begun processing Bitcoin withdrawals as scheduled. That is meaningful progress and should be acknowledged plainly. This is an account of a breach and a staged restoration of access—not a claim that Bitget has collapsed or that all customer money is gone. [The Block’s September 28 report](https://www.theblock.co/news/business/2026-09-28-bitget-starts-phased-withdrawal-resumption-416965).

Nevertheless, restoring access after an interruption is different from having maintained it. Consider a person who needs to pay a supplier, meet an obligation, or move funds into a safer arrangement. Even if their eventual balance is preserved, their choices during the interruption were constrained. This is an illustration of the risk, not a claim about a particular Bitget customer.

A complete definition of protection must include access as well as reimbursement.

## A protection fund is useful. It does not confer control.

A sufficiently funded reserve can prevent a platform theft from becoming a customer loss. Customers should welcome that protection. TRM’s September 25 account cited a Bitget protection fund of approximately $464 million and the exchange’s statement that it covered the loss. That is a reported figure from that date, not a claim about the fund’s balance today. [TRM Labs](https://www.trmlabs.com/resources/blog/bitget-loses-usd-3516-million-in-hot-wallet-breach-in-likely-north-korea-attack).

But a reserve changes who may absorb a financial loss; it does not change who authorizes withdrawals. The customer still depends on the institution to assess the incident, deploy resources, repair infrastructure, and restore service.

When evaluating any protection fund, useful questions concern its assets, custody, scope, exclusions, legal commitments, and ability to cover multiple events. A headline dollar amount cannot answer those questions on its own. Nor should a privately maintained fund be casually described as equivalent to government deposit insurance.

The same discipline applies to proof of reserves. The PCAOB’s Office of the Investor Advocate has warned that these reports are not audits and may omit liabilities, asset-holder rights, borrowed reserves, and the effectiveness of governance or internal controls. They are also tied to a point in time. [PCAOB investor advisory](https://pcaobus.org/resources/information-for-investors/investor-advisories/investor-advisory-exercise-caution-with-third-party-verification-proof-of-reserve-reports).

An exchange can hold substantial assets and still suffer a failure in the process that moves them. Financial resilience and operational security answer different questions. Neither gives a depositor a personal signing key for the exchange’s pooled funds.

## Three earlier failures, three different warnings

It would be misleading to treat every exchange crisis as the same event. Theft, fraud, and prolonged insolvency proceedings have different causes and different outcomes. They nevertheless expose a recurring dependency: customers must wait for decisions made elsewhere.

### Mt. Gox: the cost measured in years

Mt. Gox’s trustee was already reporting on bankruptcy proceedings and the recovery of assets in July 2014. A decade later, in June 2024, the rehabilitation trustee announced that Bitcoin and Bitcoin Cash repayments would begin that July. The notice described the technical, regulatory, and coordination work required before repayment. [2014 trustee report](https://www.mtgox.com/img/pdf/20140723_report_en.pdf); [2024 repayment notice](https://www.mtgox.com/img/pdf/20240624_announcement_en.pdf).

The lesson is not captured by a missing-coin total alone. It is the interval between believing an asset is available and having the freedom to use what can eventually be recovered.

During such an interval, an owner’s life continues. Expenses arrive; circumstances change. A claim handled through a rehabilitation process is not operationally equivalent to bitcoin that the holder can transfer. Eventual distributions matter, but they do not erase the years in between.

### FTX: account security could not stop insider misuse

FTX illustrates a different failure. In March 2024, the U.S. Department of Justice announced Sam Bankman-Fried’s 25-year prison sentence. It described the misappropriation of billions of dollars deposited by customers, including their use for investments, political contributions, and repayment of Alameda Research’s debts. Prosecutors put the theft of customer money at more than $8 billion. [U.S. Department of Justice](https://www.justice.gov/usao-sdny/pr/samuel-bankman-fried-sentenced-25-years-prison).

No customer could fix that arrangement by choosing a stronger login password. The central problem was what people inside the institution could do with assets entrusted to them.

This does not establish that other exchanges behave like FTX. It establishes why custody requires scrutiny of governance, segregation, legal rights, and business incentives—not merely the appearance of a polished application. A clean interface tells you little about authority behind it.

### Bybit: cold storage still depended on a signing workflow

The FBI attributed the theft of approximately $1.5 billion from Bybit on or about February 21, 2025, to North Korea. Bybit subsequently reported that compromised credentials belonging to a Safe developer enabled an attack that deceived signers into approving a malicious transaction. [FBI public notice](https://www.fbi.gov/investigate/cyber/alerts/2025/north-korea-responsible-for-1-5-billion-bybit-hack); [Bybit’s February 26 investigation update](https://www.bybit.com/en/press/post/bybit-confirms-security-integrity-amid-safe-wallet-incident-no-compromise-in-infrastructure-blt9986889e919da8d2).

Cold storage reduces exposure, but assets eventually have to move. The process that interprets and authorizes that movement remains part of the security system. This is relevant to institutions and individual users alike: multiple signatures and protected keys are valuable, but they cannot make an inaccurately understood transaction safe.

Mt. Gox, FTX, Bybit, and Bitget should not be collapsed into one accusation. Their shared lesson is narrower and stronger: control of assets depends on the entire custody arrangement, including the people, software, and procedures permitted to move them.

## What self-custody changes

A wallet does not literally contain coins. It manages the keys and related information needed to interact with assets recorded on a blockchain. With genuine self-custody, you control the credentials that authorize spending instead of asking an exchange to authorize a withdrawal. The SEC’s custody bulletin explains this distinction and the responsibilities it creates. [Investor.gov: crypto asset custody basics](https://www.investor.gov/introduction-investing/general-resources/news-alerts/alerts-bulletins/investor-bulletins/crypto-asset-custody-basics-retail-investors-investor-bulletin-0).

That change has several practical consequences.

**An exchange’s withdrawal policy stops governing those assets.** Once assets have been transferred to a wallet you control, a trading platform cannot impose its own withdrawal queue on that wallet. Your ability to transact still depends on the network, fees, valid credentials, and the rules of the asset itself.

**The exchange’s balance sheet stops being the custody foundation for those holdings.** If you keep native assets under your own keys, you do not need that exchange to remain solvent to authorize a transaction. This advantage disappears for funds you subsequently deposit into a custodial service. It also should not be confused with eliminating the separate risks of stablecoin issuers, bridges, or lending protocols.

**You can choose how much authority to expose.** Daily spending, long-term holdings, and experimental applications do not have to share one wallet. Separating them can limit the consequences of a mistake. Merely adding more accounts derived from the same exposed recovery phrase does not provide that isolation.

**Recovery can be designed around credentials you control.** For a standard recovery-phrase wallet, retaining the correct phrase—and any additional passphrase and necessary account information—can allow restoration in compatible software. Compatibility and the precise backup requirements must be checked before they are needed.

These are concrete reasons self-custody can be a better arrangement for long-term holders who are prepared to manage it. It removes the exchange’s discretionary control over the assets held that way. It does not make every transaction, token, device, or wallet safe.

## The responsibilities that come with the keys

A serious defense of self-custody must address its failures as carefully as those of exchanges.

If your recovery material is stolen, an attacker may gain the same spending authority you have. If the only usable recovery material is lost, there may be no institution able to restore access. The SEC’s custody guidance emphasizes that self-custody places responsibility for private-key security on the holder. [Investor.gov custody bulletin](https://www.investor.gov/introduction-investing/general-resources/news-alerts/alerts-bulletins/investor-bulletins/crypto-asset-custody-basics-retail-investors-investor-bulletin-0).

And a key need not be stolen for a user to approve something harmful. In December 2023, the Ledger Connect Kit incident injected malicious code into applications using the affected library and tricked users into signing asset-draining transactions, according to Ledger’s incident report. That was an attack on a connection and signing experience, not evidence that every Ledger hardware device had been broken. [Ledger’s security incident report](https://www.ledger.com/blog/security-incident-report).

The point is uncomfortable but necessary: a self-custody wallet can faithfully execute the wrong instruction. A convincing screen, urgent message, or apparently familiar website can induce that instruction.

Self-custody also leaves other risks intact. Asset prices can fall. Networks can become congested. Smart contracts can contain vulnerabilities. Some tokens give issuers administrative powers; holding their keys does not remove those powers. Hardware can fail, software can contain defects, and backups can be incomplete.

For someone unable to maintain safe recovery procedures, a well-chosen custody service may be preferable to an improvised setup they do not understand. The right response is to develop competence gradually. Moving everything at once out of fear can replace one serious risk with another.

The relevant question is which risks you can understand, reduce, and bear—not which product promises a life without risk.

## A practical way to take control

Moving toward self-custody is a process of verification. It should feel deliberate.

1. **Separate trading from holding.** Decide what actually needs to remain on an exchange for near-term activity. A convenient trading account does not have to become the permanent home of every asset you own.

2. **Create the wallet through a verified source.** Use the provider’s authentic distribution channel. Never adopt a recovery phrase supplied by a stranger, a supposed support agent, or a website offering a pre-funded wallet.

3. **Understand the backup before adding meaningful funds.** Know exactly what restores access, how it is protected, and what happens if your phone is lost. Check the wallet’s supported recovery procedure without entering secrets into a website, chat, or untrusted device. Never erase your only working wallet to “test” an uncertain backup.

4. **Check the asset and network on both ends.** Similar names and matching-looking addresses are not enough. Confirm that the receiving wallet supports the exact asset on the exact withdrawal network, including any required memo or destination tag.

5. **Make a small test transfer.** Verify receipt and the ability to use the funds before moving more. Where appropriate, test a small outgoing transaction too. A successful test establishes that particular route; it does not guarantee future safety.

6. **Keep long-term holdings away from casual signing.** Consider hardware-backed arrangements for substantial holdings, and assess whether you can operate them safely. Use separate credentials for experimental activity. Read permissions and transaction details rather than approving by habit.

7. **Plan for loss, incapacity, and inheritance.** A recovery method that only works while you are present and remember everything is unfinished. Document a secure process without leaving all the ingredients for theft together.

If an exchange has paused withdrawals, do not trust messages offering a special exit, priority approval, or paid recovery shortcut. Follow verified announcements and wait for the relevant withdrawal route to reopen. No legitimate support conversation requires your wallet’s recovery phrase.

These practices cannot guarantee safety. They can make control informed and usable.

## Why we build Oath Wallet

Oath Wallet is built around a simple commitment: the wallet should serve the person who holds it. Our [product overview](https://oathwallet.org/features) describes that approach, and our [source repository](https://github.com/devdasx/oath-wallet) is available for inspection.

We believe a wallet should make receiving, holding, sending, and recovery understandable. A user should be able to distinguish a transaction from an approval, a backup from a login, and a wallet balance from a platform’s promise. Good design helps people notice the decisions that matter.

Our preference for self-custody does not give us permission to make absolute claims. Open source creates an opportunity for scrutiny; it is not proof that software has no vulnerabilities. A readable interface helps; it cannot remove the need for careful decisions. No wallet provider, including Oath Wallet, should ask people to abandon judgment in exchange for a reassuring brand.

The point is to place meaningful authority with the user and make the responsibilities of that authority clear.

## The question to ask before the next incident

When an exchange suffers a breach, attention naturally turns to the amount stolen, the suspected attacker, and the size of the recovery fund. Those are essential facts. They are not the only facts a customer needs.

Ask a more personal question: **if this institution closes its withdrawal system tonight, what can I still do with my assets tomorrow?**

If the answer depends entirely on that institution’s timetable, you have identified a custody dependency. Strong authentication, visible reserves, and responsible incident management may reduce parts of the risk. They do not remove that dependency.

Bitget’s recovery efforts deserve fair reporting. Its breach still demonstrates why protection cannot be measured only by whether a company ultimately absorbs a loss. People also need the ability to act.

Self-custody, practiced carefully, gives that ability a different foundation: credentials you control, backups you understand, and transactions you choose to authorize.

A balance is reassuring. The authority to use it is what makes it yours in practice.

---

*Reporting note: researched and updated on September 28, 2026. The Bitget investigation and withdrawal restoration remain in progress. Company statements are identified as such; attribution and preliminary technical explanations should not be treated as final forensic findings. The headline rounds the September 25 estimate of $387.5 million to $388 million, consistent with Bitget’s latest public account. This article is published by Oath Wallet, a self-custody wallet provider, and explains our editorial position rather than offering individualized investment advice.*

## Sources and further reading

- [Bitget: September 25 fund-tracing update and revised $387.5 million estimate](https://www.bitget.com/support/articles/12560603896108).
- [Bitget: updated incident explanation, chronology, product distinction, and investigation status](https://www.bitget.com/amp/academy/bitget-security-incident-what-happened-timeline-impact-response).
- [Bitget: phased withdrawal restoration schedule](https://www.bitget.com/support/articles/12560603896110).
- [TRM Labs: Bitget investigation and fund-flow analysis](https://www.trmlabs.com/resources/blog/bitget-loses-usd-3516-million-in-hot-wallet-breach-in-likely-north-korea-attack). Its headline retains the earlier estimate.
- [The Block: Bitcoin withdrawals begin resuming, September 28, 2026](https://www.theblock.co/news/business/2026-09-28-bitget-starts-phased-withdrawal-resumption-416965).
- [PCAOB Office of the Investor Advocate: limitations of proof-of-reserve reports](https://pcaobus.org/resources/information-for-investors/investor-advisories/investor-advisory-exercise-caution-with-third-party-verification-proof-of-reserve-reports).
- [Mt. Gox trustee: July 2014 bankruptcy report](https://www.mtgox.com/img/pdf/20140723_report_en.pdf) and [June 2024 repayment announcement](https://www.mtgox.com/img/pdf/20240624_announcement_en.pdf).
- [U.S. Department of Justice: Bankman-Fried sentencing and customer-fund misuse](https://www.justice.gov/usao-sdny/pr/samuel-bankman-fried-sentenced-25-years-prison).
- [FBI: attribution of the February 2025 Bybit theft](https://www.fbi.gov/investigate/cyber/alerts/2025/north-korea-responsible-for-1-5-billion-bybit-hack).
- [Bybit: preliminary investigation update, February 26, 2025](https://www.bybit.com/en/press/post/bybit-confirms-security-integrity-amid-safe-wallet-incident-no-compromise-in-infrastructure-blt9986889e919da8d2).
- [SEC investor bulletin: crypto asset custody basics](https://www.investor.gov/introduction-investing/general-resources/news-alerts/alerts-bulletins/investor-bulletins/crypto-asset-custody-basics-retail-investors-investor-bulletin-0).
- [Ledger: December 2023 Connect Kit security incident report](https://www.ledger.com/blog/security-incident-report).

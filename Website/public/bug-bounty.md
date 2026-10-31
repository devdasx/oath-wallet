# Oath Wallet Bug Bounty

Program v1.0. Effective 2026-10-31.

Help us find vulnerabilities in Oath and make self-custody stronger for everyone.

[Report privately on GitHub](https://github.com/devdasx/oath-wallet/security/advisories/new). Private reporting is enabled; a GitHub account is required. Email alternative: care@oathwallet.org. Start with a non-sensitive summary.

## Rewards (USD)

### Low: $0

Limited security impact. Useful findings that strengthen the details.

Example: A narrowly constrained information exposure with no sensitive wallet data or meaningful privilege gain.

CVSS 0.1–3.9 (reference only).

### Medium: $250

A meaningful security weakness with limited impact or significant prerequisites.

Example: An exploitable access-control or application vulnerability affecting limited non-public data, without exposing signing keys or enabling unauthorized transfers.

CVSS 4.0–6.9 (reference only).

### High: $1,000

Substantial compromise of confidentiality, integrity or availability.

Example: A practical bypass of an important security boundary, significant sensitive-data exposure, or a serious signing flaw requiring constrained conditions.

CVSS 7.0–8.9 (reference only).

### Critical: $10,000

A direct, severe threat to wallet keys or user funds.

Example: A reproducible flaw that permits unauthorized signing, extraction of protected private keys, or irreversible loss of funds under realistic conditions. Demonstrate it only with test assets.

CVSS 9.0–10.0 (reference only).

[CVSS v4.0](https://www.first.org/cvss/v4.0/specification-document) is a reference, not an automatic payout calculation. Final severity considers demonstrated impact and the actual Oath exploit path.

## In scope

### Oath for iOS & iPadOS

The current publicly released Oath Wallet app. Include the exact app build, OS version and affected network. Focus on key protection, authentication, recovery, transaction construction and signing.

[View the app](https://apps.apple.com/app/id6780187283)

### Public source

Security-relevant Oath code in devdasx/oath-wallet. Pin the commit and demonstrate a reachable impact in a current supported feature. A source-only finding must identify the affected code and must not claim it proves App Store binary behavior.

[Explore the source](https://github.com/devdasx/oath-wallet)

### Oath websites

Oath-controlled application behavior on oathwallet.org, help.oathwallet.org and articles.oathwallet.org. Use only your own account and test data. These exact hosts are in scope; other subdomains and infrastructure are not included automatically.

[Visit the website](https://oathwallet.org/)

## Out of scope

- Third-party wallets, dApps, blockchains, RPC providers, Apple, GitHub, cloud providers and other services are not authorized targets. A demonstrated vulnerability in Oath’s own use of a dependency can still qualify.
- Unverified scanner output, dependency version alerts, missing headers or best-practice recommendations without a reproducible security impact.
- Cosmetic issues, ordinary product bugs, unsupported features, price differences, market losses and service interruptions without an Oath security vulnerability.
- Expected behavior that requires the victim to disclose their recovery phrase, approve the accurately displayed malicious transaction, or grant the attacker full device control, unless a separate Oath security boundary is demonstrably bypassed.
- Issues already publicly documented, already known to Oath, or duplicate reports of the same root cause. Still report a materially different exploit path or an incomplete fix with new evidence.

## Testing rules

### Use a controlled environment

Use local builds, isolated forks or testnets with disposable wallets and synthetic data. Website testing must be non-destructive and limited to accounts and data you control. Do not use real user funds or send mainnet transactions to prove impact.

### Stop at the smallest proof

Do not access, copy, change or delete another person’s data. If you encounter it unexpectedly, stop immediately and report the minimum redacted evidence privately. Do not continue exploiting the issue or retain unnecessary data.

### Keep services available

No denial-of-service, stress tests, bulk scanning, brute force, spam, phishing, social engineering or physical attacks. Do not persist access, install malware, weaken protections or target staff, users or third-party infrastructure.

### Coordinate disclosure

Report promptly through the private channel. Keep exploit details private while we investigate and coordinate a disclosure date with us. Do not put vulnerabilities, secrets or personal data in public GitHub issues or social posts.

## Eligibility and payment

- Submit an original, reproducible security issue affecting an in-scope target. Explain the attacker’s prerequisites, the violated security boundary and the demonstrated impact.
- The first actionable report of a unique issue is eligible. Multiple symptoms of one root cause are assessed together, not paid separately. Findings from work already commissioned and paid for by Oath are not paid again under this program.
- Follow the testing rules and applicable law. If the ownership of a target or the safety of a test is unclear, ask before testing. This program does not authorize access to third-party systems.
- Oath validates the report and confirms its final severity with the researcher. Eligible accepted findings receive the listed USD reward for that severity; Low findings have no monetary reward. Informational reports are not paid. Submission alone does not establish eligibility.
- Payment arrangements and any necessary payment-compliance information are handled privately after acceptance. Do not include payment details or identity documents in the initial report. Oath will never ask for a payment, recovery phrase or private key to release a bounty.

## Review process

1. **Report privately:** Share the affected version, minimal reproduction and clear impact. Use the template below and redact sensitive information.
2. **Reproduce & assess:** We review scope, reproduce the issue and discuss severity. We may request a smaller proof or additional environment details.
3. **Resolve & reward:** We coordinate remediation, confirm eligibility and arrange the applicable reward privately. Response, fix and payment dates are confirmed in the report thread; no fixed turnaround is promised.
4. **Disclose together:** Agree on a safe publication date after remediation. Researcher credit is optional and requires your consent.

## Report template

[Download the report template](https://oathwallet.org/bug-bounty-report-template.txt). Do not include real wallet secrets or other people's data.

## Questions

### How is severity decided?

We assess demonstrated impact, exploitability, required privileges, user interaction and affected users. FIRST’s CVSS v4.0 ranges provide a reference, not an automatic payout calculation. Include a vector if helpful; Oath confirms the final category with an explanation. A theoretical maximum impact is not the same as a reproducible exploit.

### Do Low findings receive a reward?

Low findings have a $0 monetary reward. We still welcome actionable reports that improve Oath. Informational feedback is also welcome, but is not eligible for payment.

### Can I submit without a GitHub account?

Yes. Email care@oathwallet.org with the subject “Security report — Oath”. Start with a non-sensitive summary and ask for a private transfer route if your evidence needs one. Never send real recovery material, unredacted personal data or executable attachments.

### Can I test with a funded wallet?

Use a disposable wallet with no real funds. Demonstrate financial impact locally or on a testnet using test assets. Do not move, freeze or recover anyone else’s assets, even to prove a vulnerability.

### Is this a guarantee of legal immunity?

No. The permitted activities are limited to the scope and testing rules above. This page cannot authorize activity on third-party systems or waive another party’s rights. Ask us privately before any test whose authorization is unclear.

### What if my report is a duplicate or I disagree with the assessment?

We assess one root cause as one issue and use the first actionable submission. If you believe the assessment missed an exploit path or impact, reply in the private thread with the additional evidence. Do not create public issues containing exploit details.

### Does a bounty mean Oath has been independently audited?

No. This program invites vulnerability research; it is not an independent security audit, a certification, or a guarantee that software has no vulnerabilities.

### What if the program changes?

The published scope and rewards may be updated prospectively. We assess a report using the program version in effect when it was received. This page identifies its version and effective date so researchers can reference them.

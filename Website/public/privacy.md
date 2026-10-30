# Privacy Policy

Last updated: October 30, 2026

**In short:** No account signup, email or KYC is required to use the wallet. You control the wallet credentials. The App Store version of Oath Wallet does not send us app analytics or automatic error reports. Optional encrypted backups, deliberate exports, WalletConnect and network services and the website's separate features have the data boundaries described below. We do not sell personal data or share it for cross-context behavioural advertising.

## 1. Who we are

This Privacy Policy explains how STAGE AND STYLE COLLECTIVE LLC, 2103 Condor Ct, Redmond, Oregon 97756-8281, United States (“Oath”, “we”, “us”) handles personal data when you use Oath Wallet distributed through the App Store and the Oath website (the “Service”). We are the data controller for the limited personal data described here.

Contact: care@oathwallet.org.

## 2. Our approach

The App Store app does not collect user analytics or automatically upload error reports. Network requests, optional services, website visits and information you choose to send us are described separately below. We do not require an account, name, email address, phone number or identity documents to use the wallet app or browse the website. The optional newsletter requires an email address.

## 3. Wallet credentials and device storage

In the 4.1.14 public source, recovery material is sealed in an authenticated local vault using device-only Keychain storage and an additional installation key in the protected app container. Public wallet metadata and transaction records are stored separately in the local database. Signing takes place locally; network providers receive public queries and signed transactions, not the spending credentials used to sign them.

Optional encrypted iCloud backup can store eligible wallet material at your request. Manual export can also reveal or copy recovery material under your control. Do not interpret on-device storage as a promise that a user-authorized export never leaves the device.

Explicit copies of recovery phrases, private keys and passphrases stay on the current device and expire from the system clipboard after 60 seconds. Information already pasted into another app is outside that expiry.

Face ID and Touch ID are handled by iOS; Oath does not receive your biometric templates. Public source publication does not independently establish a match to a distributed App Store binary. See [the security evidence and version scope](https://oathwallet.org/security).

## 4. Password-encrypted backup and WalletConnect

Optional iCloud backup encrypts an eligible wallet on the device with AES-256-GCM. Its key is derived from a separate backup password using PBKDF2-HMAC-SHA256 with 600,000 rounds and a fresh salt. Restore requires both the encrypted backup file and its backup password. Oath does not receive the password or a plaintext backup. Apple operates iCloud Drive under its own policies.

Electrum and aezeed wallets are not eligible for iCloud backup in 4.1.14; preserve their original recovery material. Existing backup files remain outside the app-reset boundary. The former passkey-based backup and nearby-iPhone transfer flows are not current recovery methods. Keep an older device until a supported recovery method is verified.

WalletConnect uses encrypted relay connections to pair with a dApp. A user-approved connection can share public accounts and requested signatures or signed transactions with that dApp. It does not send recovery phrases or private keys. Review the destination and request before approving.

## 5. Data processed to provide the Service

To show balances, prices and history and to broadcast transactions, the app connects to blockchain nodes and price-data services. These requests can reveal:

- Your public wallet addresses and transactions (which are public on blockchains by design)
- Your device’s IP address and basic technical information (such as app version and device type)
- Your chosen display currency and language

## Notification services in earlier releases

The 4.1.14 public source does not register wallet addresses or notification tokens with an operator notification service. Earlier releases and separately enabled services may have registered public wallet information, notification tokens and device metadata. Contact us about data you previously supplied to those services; updating the app alone does not delete earlier service records.

## Website visitor statistics

On oathwallet.org, we use first-party website analytics to understand visits and App Store download-button clicks. A random, first-party browser identifier is stored in a Secure, HttpOnly cookie for up to one year. Session information in your browser groups activity into visits after 30 minutes of inactivity. We record page paths (not query strings), referral domains (not full referral URLs), broad browser/device categories, and approximate country/city and rounded coordinates derived by Cloudflare from your IP address. This is not GPS location and does not request device-location access. Our analytics records do not store your raw IP address or link visits to wallet data.

Restricted administrators can view statistics, anonymous returning-browser history, and visit/download alerts in the restricted administration console. Detailed events are retained for up to 400 days. Clearing the cookie creates a new anonymous browser identity. We exclude detected automated traffic and honour Global Privacy Control and Do Not Track signals. You can enable those browser settings to opt out of this website analytics. Download clicks are not evidence of app installation.


## Optional Oath Notes newsletter

If you choose to subscribe, we store your email address, selected topics, signup source page, consent version and timestamps, subscription status and signup method, and subscription changes to provide the newsletter. Newsletter signup is optional and is not connected to wallet addresses, balances, recovery phrases, or private keys. Submitting the signup form subscribes you immediately; no email confirmation is required. Emails may include Oath Wallet releases, crypto news and market prices, security alerts, and practical guides.

Our email delivery provider processes the recipient address and message content. We record sending, delivery, bounce, complaint, and unsubscribe events. When engagement measurement is enabled for a campaign, tracking pixels and redirect links can report opens and clicks. These are approximate signals: email privacy services and security scanners may create events without a person reading or clicking. We do not store the IP addresses or user-agent strings received in newsletter event reports.

You can change topics or unsubscribe using the private link in an email. Unsubscribed addresses and permanent delivery failures are suppressed from future campaigns. We retain subscription and consent records while needed to deliver the newsletter, honour opt-outs, and resolve delivery or abuse issues. Contact care@oathwallet.org to request access or deletion; a minimal suppression record may be retained to prevent future unwanted messages.

The website remembers that the signup dialog appeared using browser local storage and a preference cookie (up to 400 days). This preference does not identify you and is not linked to subscriber records. It stops repeated prompts in that browser. Clearing browser storage, private browsing, or using another device can show the dialog again. Short-lived, keyed IP hashes help limit automated signup and login attempts; raw IP addresses are not saved in the newsletter database.

## 6. App analytics and error reports

The App Store version of Oath Wallet does not automatically upload app errors, crash reports, usage analytics or diagnostic logs to our servers. Website visitor statistics and information you voluntarily send to support are separate from the app and are described in this policy.

If you choose to share analytics with app developers in iOS settings, Apple may provide us with aggregated crash reports and performance data that do not identify you. You can change this at any time in Settings › Privacy & Security › Analytics & Improvements.

## 7. Support requests

If you contact care@oathwallet.org, we process your email address and the contents of your message to respond. Never include your recovery phrase or private keys.

## 8. Why we process data (legal bases)

Where laws such as the EU/UK GDPR apply, we rely on:

- Performance of a contract — to provide the Service you request (connecting to networks, showing prices)
- Legitimate interests — to keep the Service secure, prevent abuse and fix bugs, balanced against your rights
- Consent — for the optional newsletter, which you can withdraw at any time
- Legal obligation — where we must comply with applicable law

## 9. What we don’t do

We do not sell personal data, “share” it for cross-context behavioural advertising, build advertising profiles, use third-party ad trackers, or make decisions about you based solely on automated processing that produce legal effects.

## 10. Sharing with service providers

We may use a small number of service providers (such as blockchain node providers, price-data providers, hosting and email providers) who process data on our behalf under written contracts that require confidentiality and security. We may disclose information where required by law or to protect rights and safety, and we will resist over-broad requests where the law allows.

## 11. International transfers

Our providers may process data in countries other than yours. Where required, we protect transfers with appropriate safeguards such as the European Commission’s Standard Contractual Clauses, the UK International Data Transfer Addendum, or other lawful transfer mechanisms.

## 12. Retention

Network and price requests are not stored by us beyond what our providers need for security logs (typically no longer than 30 days). Support emails are kept only as long as needed to resolve your request, then deleted, unless we must keep them by law.

## 13. Security

The published source uses device-only Keychain storage, local signing, authenticated encryption for the local vault and optional iCloud backup, and encrypted network connections. Blockchain private keys are not described as Secure Enclave signing keys. The version-specific evidence and limitations are documented at https://oathwallet.org/security; published source is available at https://github.com/devdasx/oath-wallet.

## 14. Your rights

Depending on where you live, you may have the right to access, correct, delete or port your personal data, to object to or restrict processing, and to withdraw consent. Removing the app removes its installation key, but does not delete separate iCloud backups or earlier service records; use the deletion methods described below. To exercise any right, email care@oathwallet.org. We will respond within the time required by law and will not discriminate against you for exercising your rights.

You also have the right to complain to your local data-protection authority.

## 15. Regional information

We aim to meet the requirements of privacy laws worldwide, including:

- European Union, EEA and United Kingdom — GDPR and UK GDPR
- United States — CCPA/CPRA (California) and other state privacy laws; we honour Global Privacy Control signals, and we do not sell or share personal information
- Brazil — LGPD
- Canada — PIPEDA and applicable provincial laws
- Australia — Privacy Act 1988 and the Australian Privacy Principles
- Japan — APPI · South Korea — PIPA · Singapore — PDPA · Thailand — PDPA
- India — Digital Personal Data Protection Act 2023
- China — PIPL
- Saudi Arabia — PDPL · United Arab Emirates — PDPL · Türkiye — KVKK
- South Africa — POPIA · Nigeria — NDPA · Kenya — Data Protection Act

## 16. Children

The Service is not directed to children under 13 (or under 16 where required by local law), and we do not knowingly collect their personal data. If you believe a child has contacted us, email care@oathwallet.org and we will delete the information.

## 17. Deleting your data

Use the app’s wallet-removal or reset controls for their supported local deletion scope, and verify your independent recovery material first. Deleting the app alone does not guarantee removal of Keychain items. iCloud backups are outside the app-reset boundary and must be managed separately through your iCloud storage. Assets remain on their blockchains; future access depends on retaining the correct recovery material and any required passphrase or output-specific information. To delete support correspondence, email care@oathwallet.org from the address you used.

## 18. Changes to this policy

We will post any changes here and update the “Last updated” date. For material changes, we will notify you in the app before they take effect.

Questions: care@oathwallet.org

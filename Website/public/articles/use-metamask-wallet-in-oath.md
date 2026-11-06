# Use an Existing MetaMask Wallet in Oath

Use a compatible MetaMask EVM account in Oath on iPhone. Compare phrase and private-key imports, additional accounts, networks and asset compatibility.

Oath can derive the first ordinary EVM account from a compatible MetaMask Secret Recovery Phrase. You can also import an individual EVM private key for a software account. Both routes access an existing address; they do not send funds, change networks or remove MetaMask's access.

This guide covers ordinary EVM accounts in Oath 5.0.2 (104). MetaMask can contain several kinds of accounts, so identify the account you actually need before importing anything.

## Choose the right import route

| Your MetaMask account | Verified route in this guide | Important limit |
| --- | --- | --- |
| First EVM account derived from its Secret Recovery Phrase | Import the original BIP39 phrase | Oath's default EVM path is `m/44'/60'/0'/0/0`. Verify the address; a displayed account name is not proof of its derivation. |
| A later ordinary software EVM account, or a separately imported EVM key | Import that account's private key using Ethereum & EVM | Recovers that one address on supported EVM networks, not the other accounts behind a phrase. |
| Hardware-connected account | Outside this software-import guide | Keep the hardware wallet's recovery phrase on its hardware recovery route. |
| Smart accounts, multisig wallets, delegated account behavior, Snaps or non-EVM accounts | Outside this guide's verified scope | Possessing an EVM signing key does not establish compatibility with the account's additional contract logic or other networks. |

MetaMask documents its [default phrase derivation path](https://support.metamask.io/configure/wallet/importing-a-seed-phrase-from-another-wallet-software-derivation-path/). Its [account restoration guidance](https://support.metamask.io/configure/accounts/how-to-add-missing-accounts-after-restoring-with-secret-recovery-phrase/) also distinguishes phrase-derived accounts from separately imported and hardware accounts. A phrase from one wallet does not include an unrelated imported key.

## Import the first phrase-derived EVM account

1. In MetaMask, identify the original phrase-backed account and record its full public address. Keep MetaMask and your existing recovery backup available.
2. Open Oath and choose **Import wallet**, or use **Settings → Wallets** if Oath is already set up.
3. Enter the original Secret Recovery Phrase in order. Choose BIP39 if the app asks for the format. Never enter it into this website, chat, support or an online checker.
4. Complete setup and name the wallet. If the original recovery material required an additional BIP39 passphrase, restore that exact passphrase wallet using Oath's [passphrase guide](https://articles.oathwallet.org/add-bip39-passphrase-oath-wallet). MetaMask's unlock password is not a BIP39 passphrase.
5. Open Ethereum Receive in Oath and compare the full address with MetaMask. Then check each enabled EVM network where that address holds assets.

Read [Import a recovery phrase](https://help.oathwallet.org/articles/import-recovery-phrase) for the Oath controls. A Google, Apple or Telegram sign-in, MetaMask password, JSON keystore or browser profile is not an input for this Oath phrase-import route.

## Handle Account 2, Account 3 and imported keys separately

Do not assume importing the phrase into Oath will list all MetaMask accounts. This guide verifies the first EVM account for phrase import. Later MetaMask accounts use different keys; their displayed names may also have been changed.

For an ordinary software EVM account whose private key you can export from MetaMask, use the [official private-key export instructions](https://support.metamask.io/configure/accounts/how-to-export-an-accounts-private-key/). In Oath, choose **Import private key**, select **Ethereum & EVM**, and enter the original key in the app. Complete setup and compare the full address. Oath accepts the EVM hexadecimal key format with or without its `0x` prefix. Keep the key out of websites, messages and screenshots.

This imports one account. It does not add a recovery phrase, restore sibling accounts or import MetaMask's encrypted JSON file. Do not export a hardware wallet's seed to use this route. See [Oath's private-key import guide](https://help.oathwallet.org/articles/import-private-key).

## Which assets remain accessible?

At the same ordinary EVM address, the native coin and tokens stay on their original chain. Check [Oath's network directory](https://oathwallet.org/networks) and [token catalog](https://oathwallet.org/tokens) for available scope. A USDC balance on Base does not become USDC on Ethereum, and matching symbols do not establish matching contracts.

Token visibility, NFT support and staking or DeFi interfaces are separate from key compatibility. Oath may not display or provide actions for every position associated with an address. Keep an appropriate original interface for those positions. Existing token approvals and any account delegation persist on-chain; importing does not revoke them or undo contract behavior.

The import does not copy custom RPC settings, manually added token lists, address-book names, local activity labels or connected dApp sessions. Establish new sessions for supported dApps through [WalletConnect in Oath](https://oathwallet.org/features/walletconnect). Review [token approvals](https://oathwallet.org/features/revoke-token-approvals) separately.

## Empty account or wrong address?

First check that you selected the intended wallet and account. A later MetaMask account will not match Oath's first phrase-derived account. Check the original phrase, any additional passphrase and whether the source account was separately imported or hardware-connected.

If the address matches, check the exact chain and token contract, then allow available balances to refresh. Provider discovery can be incomplete. Do not treat missing display data as proof that a transfer or recovery failed, and do not remove your original wallet until you have checked all the accounts you need.

There is no network fee to derive an address from recovery material. Later sends and supported approval revocations are on-chain operations and require the network's fee asset. If you want new keys, create and back up a new Oath wallet and make separate, verified transfers; importing the old phrase keeps the old keys.

## What we verified

Checked November 6, 2026 against [Oath 5.0.2 (104) source](https://github.com/OathWallet/oath-wallet/tree/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca). Source review covers the [default EVM derivation](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/OathAtmosphere/Wallet/OathWalletEngine.swift) and [private-key import](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/OathAtmosphere/Wallet/OathPrivateKeyImport.swift). Offline public vectors check the first EVM address, distinguish the next account, and reproduce that account's address from its individual key. This is derivation evidence, not a live transfer test or verification of smart-account behavior.

[Get Oath for iPhone](https://apps.apple.com/us/app/oath-bitcoin-crypto-wallet/id6780187283) · [Move from Trust Wallet](https://articles.oathwallet.org/move-from-trust-wallet-to-oath) · [Restore an Electrum Bitcoin wallet](https://articles.oathwallet.org/restore-electrum-bitcoin-wallet-on-iphone)

## Check the account in Oath

![Oath receiving screen with sample data](https://articles.oathwallet.org/assets/articles/editorials/use-metamask-wallet-in-oath/oath-receive.webp)

Oath 4.0.3 app screenshot with sample data. Check the exact network as well as the full address. This older capture does not establish that every MetaMask account was imported.

## After checking compatibility

- [Ethereum account and fee guidance](https://oathwallet.org/networks/ethereum)
- [Base account and fee guidance](https://oathwallet.org/networks/base)
- [Review existing token approvals](https://oathwallet.org/features/revoke-token-approvals)
- [Find the network fee asset](https://oathwallet.org/networks/fees)
- [Read current release information](https://articles.oathwallet.org/oath-wallet-release-history)

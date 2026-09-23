# Oath Wallet

**A free, open-source self-custody crypto wallet for iPhone and iPad.**

Oath Wallet lets you hold, send, and receive Bitcoin, Ethereum, Solana, and assets across 22 additional production mainnets while keeping control of your wallet credentials. There is no Oath Wallet account, custody service, swap engine, in-app Web3 browser, or dApp approval layer.

[Download on the App Store](https://apps.apple.com/us/app/id6780187283) · [Website](https://oathwallet.org/) · [Security model](https://oathwallet.org/security) · [Supported networks](https://oathwallet.org/features) · [Journal](https://oathwallet.org/articles)

## What Oath Wallet is built for

- **Self-custody:** wallet credentials are created and used on the device. Oath Wallet cannot sign for you or recover a lost recovery phrase.
- **Open source:** the production code is available under the MIT License for inspection, building, and independent review.
- **Clear network boundaries:** accounts, address formats, native assets, token identities, fees, and transaction status remain network-specific.
- **Focused attack surface:** Oath Wallet deliberately omits buying, selling, swapping, an in-wallet browser, and standing dApp approvals.
- **Native Apple experience:** SwiftUI interface for iPhone and iPad with Face ID or device-passcode app locking, accessibility, localization, and platform-native navigation.
- **Portable recovery:** standard recovery-phrase and private-key import paths, optional BIP-39 passphrases, encrypted backup, and direct encrypted iPhone-to-iPhone transfer.

## Supported production mainnets

| Family | Networks |
| --- | --- |
| Bitcoin-style | Bitcoin, Bitcoin Cash, Litecoin, Dogecoin |
| EVM | Ethereum, BNB Smart Chain, Arbitrum One, Base, Polygon PoS, OP Mainnet, Avalanche C-Chain, Gnosis Chain, Linea, Scroll, Taiko Alethia, Telos EVM, X Layer |
| Other account models | Solana, TRON, TON, Sui, Aptos, NEAR Protocol, Stellar, XRP Ledger |

Network support means Oath Wallet derives and validates the correct account identity for that mainnet. A matching ticker, logo, or hexadecimal-looking address does not make two networks interchangeable. See the [features and supported networks](https://oathwallet.org/features) for current product information.

## Security boundary

Oath Wallet stores sensitive wallet material locally using Apple Keychain with this-device-only protection. Recovery phrases, private keys, passcodes, passcode verifiers, API credentials, and encryption keys are not stored in the app database. Signing happens on the device; only public account data and signed transactions are sent to network infrastructure when required for wallet operation.

Self-custody also means there is no company-held recovery copy. Before funding a wallet, verify your recovery method and understand the effect of any optional BIP-39 passphrase. Start with the [security model](https://oathwallet.org/security) and [backup and restore support](https://oathwallet.org/support).

## Build from source

Requirements:

- Xcode 26.5 or newer
- iOS 26.0 / iPadOS 26.0 deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
git clone https://github.com/devdasx/oath-wallet.git
cd oath-wallet
cp Secrets.xcconfig.template Secrets.xcconfig
xcodegen generate
open Aperture.xcodeproj
```

`Secrets.xcconfig.template` documents the optional provider credentials without containing secrets. Keep the real `Secrets.xcconfig` local and uncommitted.

## Documentation for people and agents

- Official website: [oathwallet.org](https://oathwallet.org/)
- Features and supported networks: [oathwallet.org/features](https://oathwallet.org/features)
- Security model: [oathwallet.org/security](https://oathwallet.org/security)
- Guides and product notes: [Oath Wallet articles](https://oathwallet.org/articles)
- Machine-readable overview: [`llms.txt`](https://oathwallet.org/llms.txt)
- Extended machine-readable documentation: [`llms-full.txt`](https://oathwallet.org/llms-full.txt)
- MCP discovery: [`/.well-known/mcp.json`](https://oathwallet.org/.well-known/mcp.json)
- Read-only MCP endpoint: `https://oathwallet.org/mcp`

Connect from any MCP client that supports remote Streamable HTTP:

```json
{
  "mcpServers": {
    "oath-wallet-knowledge": {
      "type": "http",
      "url": "https://oathwallet.org/mcp"
    }
  }
}
```

The server is public, requires no authentication, and exposes only read-only product knowledge. It cannot access a wallet, inspect balances, process wallet credentials, sign, authorize, or broadcast transactions.

The repository also includes the earlier [`mcp-server/`](mcp-server/) implementation and [`llms-install.md`](llms-install.md) connection guide. These legacy integration files and the packages below retain their existing Aperture identifiers and configuration. Use the endpoint above for the current Oath Wallet website.

## Portable agent plugin

This repository is also a conforming [Agent Plugins 1.0](https://agent-plugins.org/)
package. Compatible clients can load the root [`plugin.json`](plugin.json) and
[`mcp.json`](mcp.json) to connect to the legacy public, read-only MCP endpoint.
The package requires no API key, secret, local process, or wallet permission.

The portable package is intended for agent clients such as Cursor and GitHub
Copilot/VS Code that support the Agent Plugins standard. It adds verified public
Oath Wallet knowledge only; installing it does not connect to, inspect, or control
the Oath Wallet iOS app or any user wallet.

The Agent Plugins project's current compatibility catalog includes VS Code,
Cursor, GitHub Copilot, ChatGPT and Codex, Kiro, Hermes Agent, OpenClaw, Grok
Bot, and NanoClaw. Each client still controls its own installation, permissions,
and enabled components.

Hermes Agent can install this repository directly, then enable the portable
plugin explicitly:

```sh
hermes plugins install devdasx/oath-wallet --no-enable
hermes plugins enable aperture-wallet-knowledge
```

## Agent Skill

Install the existing source-guidance skill from this repository:

```sh
npx skills add devdasx/oath-wallet --skill aperture-wallet-guide
```

The skill retains its `aperture-wallet-guide` identifier for compatibility and is inspectable at [`skills/aperture-wallet-guide/SKILL.md`](skills/aperture-wallet-guide/SKILL.md). It contains instructions only: no executable, account, API key, secret, or wallet connection.

## Claude plugin

Claude Code and Cowork can use the repository as an Oath Wallet knowledge plugin.
The Claude manifest is at [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json),
the source guidance is in [`skills/aperture-wallet-guide/SKILL.md`](skills/aperture-wallet-guide/SKILL.md),
and [`.mcp.json`](.mcp.json) connects to the legacy public read-only server. The
plugin requires no account, API key, secret, local executable, or access to a
user wallet.

## Gemini CLI extension

Install the public read-only knowledge extension directly from this repository:

```sh
gemini extensions install https://github.com/devdasx/oath-wallet
```

The extension adds the legacy public MCP endpoint plus concise product and safety context. It requires no API key and cannot access a wallet, private keys, recovery phrases, balances, or signing.

## Privacy and support

- Privacy policy: [oathwallet.org/privacy](https://oathwallet.org/privacy)
- Product support: [oathwallet.org/support](https://oathwallet.org/support)
- Support and security contact: [care@oathwallet.org](mailto:care@oathwallet.org) (mailbox activation in progress)
- Security information: [oathwallet.org/security](https://oathwallet.org/security)

## Contributing and responsible disclosure

Issues and pull requests are welcome when they include a reproducible problem, a narrowly scoped change, and appropriate validation. Do not post exploitable security details in a public issue; use the contact information on the [security page](https://oathwallet.org/security) instead.

## License

Oath Wallet is released under the [MIT License](LICENSE).

Cryptocurrency transactions may be irreversible. Verify the network, asset, destination, amount, and fee before authorizing a transfer. Oath Wallet does not provide investment, tax, or legal advice.

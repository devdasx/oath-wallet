# Public test material

Test fixtures are deliberately unsuitable for holding funds. They are not service
credentials or user wallet backups. Never send funds to addresses derived from them.

- BIP-39 vectors: Trezor python-mnemonic vectors and deterministic entropy examples.
- Hardhat development mnemonic: the public default development account fixture.
- `BIP39MultilingualMnemonicTests`: deterministic entropy bytes 0 through 15.
- Bitcoin Silent Payments: published BIP352 cryptographic test vectors.
- Bitcoin Core/Electrum imports: offline-generated wallets documented under
  `OathTests/Fixtures/BitcoinImport` and `ElectrumImport`, with generator scripts.
- Other signing tests use documented protocol vectors or ephemeral generated keys.

`.gitleaksignore` lists exact reviewed locations for public token addresses,
public fixture keys, Swift type declarations and cache identifiers mistaken for
API keys. New findings must be reviewed; do not suppress whole files or directories.

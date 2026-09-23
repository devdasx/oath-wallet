# Security

Oath Wallet 4.0.0 is a self-custody source release prepared for independent audit.
No independent audit or absolute security guarantee is claimed.

The core invariant is that an operator cannot obtain a wallet's private keys or
recovery phrase through this application's network services. Secrets are created,
imported, decrypted and used for signing on the device. User-authorized export,
client-encrypted iCloud backup and encrypted paired-device transfer are explicit
boundaries; see [the audit scope](docs/AUDIT_SCOPE.md).

Report issues privately to `care@oathwallet.org` once its pending activation is
complete. Until then, request a private reporting channel without including an
exploit or sensitive data in a public issue. Never provide wallet credentials.

Public test fixtures are deliberately unsafe for holding funds. They are documented
in the fixture READMEs and are not production service credentials.

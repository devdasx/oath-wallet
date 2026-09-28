# Security

Oath Wallet 4.0.0 is a self-custody source release prepared for independent audit.
No independent audit or absolute security guarantee is claimed.

The core invariant is that an operator cannot obtain a wallet's private keys or
recovery phrase through this application's network services. Secrets are created,
imported, decrypted and used for signing on the device. User-authorized export,
client-encrypted iCloud backup and encrypted paired-device transfer are explicit
boundaries; see [the audit scope](docs/AUDIT_SCOPE.md).

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/devdasx/oath-wallet/security/advisories/new).
Reports go to the repository maintainers and are not public issues. A GitHub account is required.
Include the affected app version or source commit, a description of the impact,
and reproduction steps using an unfunded test wallet. Do not include a real recovery
phrase, private key, passkey, wallet backup, or unnecessary personal data.

Do not post exploit details in public issues. If private reporting is unavailable,
request a private contact route without disclosing the vulnerability publicly.
There is no guaranteed response time or paid bug bounty promised by this policy.

Public test fixtures are deliberately unsafe for holding funds. They are documented
in the fixture READMEs and are not production service credentials.

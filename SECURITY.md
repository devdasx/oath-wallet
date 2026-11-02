# Security

Oath Wallet 5.0.0 is a self-custody source release prepared for independent audit.
No independent audit or absolute security guarantee is claimed.

The core invariant is that an operator cannot obtain a wallet's private keys or
recovery phrase through this application's network services. Secrets are created,
imported, decrypted and used for signing on the device. User-authorized export,
and client-encrypted iCloud backup are explicit
boundaries; see the [current security model](Documentation/SecurityModel.md) and [public build configuration](Documentation/PublicBuild.md).

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/devdasx/oath-wallet/security/advisories/new).
Reports go to the repository maintainers and are not public issues. A GitHub account is required.
Include the affected app version or source commit, a description of the impact,
and reproduction steps using an unfunded test wallet. Do not include a real recovery
phrase, private key, passkey, wallet backup, or unnecessary personal data.

Do not post exploit details in public issues. If private reporting is unavailable,
request a private contact route without disclosing the vulnerability publicly.
The [Oath bug bounty program](https://oathwallet.org/bug-bounty) defines eligible
targets, testing rules and USD rewards: Low $0, Medium $250, High $1,000 and
Critical $10,000. Payment applies to eligible, validated reports under that
program, not to every submission. Response and remediation times are not guaranteed.

Public test fixtures are deliberately unsafe for holding funds. They are documented
in the fixture READMEs and are not production service credentials.

## Reproducible security review

A [maintainer-commissioned, Codex-led review](https://github.com/devdasx/oath-wallet-security-review)
starts at 4.1.15 (100), commit `c7cdbde5e9f136b595500e92fbc904b107dcd8ee`.
It publishes its exact source targets, findings, tests, and outstanding coverage.
The review is **in progress**, is not independent certification, and does not
establish equivalence with Apple's distributed binary. Later changes do not
automatically inherit its conclusions.

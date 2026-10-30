# Silent Payments: What Oath 4.1.14 Does Not Support

Oath Editorial · Originally published 2026-08-30 · Updated October 30, 2026

https://articles.oathwallet.org/silent-payments-oath-reusable-bitcoin-address-without-reuse

Silent Payments receiving and discovery are not available in the current source release; retain compatible recovery tools.

## Current release guidance

Checked against [Oath 4.1.14 (98) source](https://github.com/devdasx/oath-wallet/tree/e98eba14186da8afe21c46fb9466afd464f498e1). Build 98 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## Current support

Oath 4.1.14 (98) does not provide Silent Payments receiving or discovery. The old announcement and screenshots should not be used as setup instructions for this release. The ordinary Bitcoin address choices shown by the app are separate from the sp1 Silent Payments format.

## Why words alone are not proof of recovery

Restoring a valid recovery phrase only recovers accounts the wallet knows how to derive and discover. It does not establish that a Silent Payments scanner, output history or spending path exists in the new software.

## Before replacing an older wallet

Keep the original compatible wallet, its recovery credentials and any output-specific recovery information. Verify the intended funds with software that supports that recovery path. Do not erase the source device because an unrelated ordinary Bitcoin balance appears after import.

## Future support

Use the current security model and release record to check implementation and verification scope. An older guide, a source file in a historical tag or a successful generic build does not establish support in the installed release.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v4.1.14).

# Lock Oath Down: Passcode, Biometrics and Auto-Lock

Oath Editorial · Originally published 2026-08-31 · Updated November 2, 2026

https://articles.oathwallet.org/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy

Choose access controls deliberately and keep a separate recovery method.

## Current release guidance

Checked against [Oath 5.0.0 (102) source](https://github.com/devdasx/oath-wallet/tree/7f40ec1158237c9358a30cf127efb26eef16a7a0). Build 102 uses the GitHub upload-only workflow; check your installed version. Older screenshots are illustrative.

## App passcode

The app passcode controls local access. In 5.0.0, enabled passcode protection derives a wrapping key using PBKDF2-HMAC-SHA256 with 600,000 rounds. It does not replace recovery words or decrypt an iCloud file protected with a different backup password.

## Biometrics

Enable supported Face ID or Touch ID if you want it to unlock Oath. iOS handles the biometric templates. Biometric success is an access check; it is not proof of a safe transaction or a substitute for reading what you authorize.

## Auto-lock

Select the delay offered in Security settings: immediately, one minute, five minutes or ten minutes. The policy uses a continuous clock so device sleep does not extend the grace period. A cold launch does not inherit an unlocked in-process grace period.

## Privacy and recovery

Use the app-switcher privacy setting where available, and protect the phone’s own passcode. Do not erase or reinstall as a way to fix a forgotten recovery credential: removal discards the installation key. Verify an independent supported backup first.

Read the [security model](https://oathwallet.org/security), [Help Center](https://help.oathwallet.org/), and [release verification record](https://github.com/devdasx/oath-wallet/releases/tag/v5.0.0).

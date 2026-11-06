# Check and revoke token approvals

See which discovered permissions can still use your assets. Review the wallet, network and approved address, then remove supported access from Oath.

[Get Oath for iOS](https://apps.apple.com/app/id6780187283) · [Read the detailed guide](https://help.oathwallet.org/articles/revoke-token-access)

![Oath token-access screen with example permissions grouped by network](https://oathwallet.org/help/assets/guide-permission-list.webp)

Oath 4.0.3 · Actual app screen with synthetic allowances. This capture does not show a completed revocation.

## See the scope

Identify the asset, network and spender or delegate before changing a permission.

## Review the fee

A supported revocation is an on-chain transaction. Oath presents its network fee before confirmation.

## Check the result

Follow Recent changes and refresh the scan. A transaction hash alone does not prove access was removed.

## Different permissions. Different limits.

The released app can discover and prepare supported removals on these network families. Coverage depends on providers, the account and the permission type.

### EVM networks

Supported token allowances, NFT approvals and Permit2 operations. Review the exact permission and network; not every contract or account-control entry can be removed.

[Ethereum](https://oathwallet.org/networks/ethereum) · [Base](https://oathwallet.org/networks/base) · [Arbitrum](https://oathwallet.org/networks/arbitrum) · [Polygon](https://oathwallet.org/networks/polygon)

### TRON

Supported token and collectible permissions use the TRON removal flow. Account-control keys have a different scope and are not ordinary token allowances.

[TRON](https://oathwallet.org/networks/tron)

### Solana

Supported token-account delegate revocations. Permanent delegates and other token restrictions are not interchangeable with removable account delegates.

[Solana](https://oathwallet.org/networks/solana)

## From approval to a verified result.

1. **Choose your wallet.** Open Settings → Permissions → Token access. Wait for the scan and read its coverage status.
2. **Inspect the permission.** Match the network, asset and approved address. Open a removable entry and review what the removal will change.
3. **Confirm, then verify.** Check the fee, confirm in Oath and follow Recent changes. Refresh the scan after confirmation before treating access as removed.

## Several permissions, one review flow.

Select supported entries to prepare a batch. Each network can require a separate transaction and fee. Results can be mixed, so check confirmed, pending and failed items individually.

[Read the batch revocation guide](https://help.oathwallet.org/articles/bulk-revoke-access)

## Questions

### Does disconnecting a dApp revoke its token approvals?

No. A WalletConnect session and an on-chain allowance are different permissions. Disconnect the session when needed, and review token access separately.

### Does an empty scan mean my wallet has no approvals?

No. Read whether coverage is checked, partial, unavailable or unsupported. An unavailable provider or incomplete discovery must not be treated as proof that no permissions exist.

### Can revoking an approval recover stolen funds?

No. Revocation can remove supported future access after it is confirmed; it does not reverse completed transfers or cancel every possible off-chain signature.

### Do I need a network fee balance?

Yes, supported revocations require the relevant network fee asset. Review the actual estimate in Oath before confirming.

## Detailed guides

- [Revoke one permission](https://help.oathwallet.org/articles/revoke-token-access)
- [Review a batch](https://help.oathwallet.org/articles/bulk-revoke-access)
- [Understand scan coverage](https://help.oathwallet.org/articles/permission-coverage)


## Release and source details

Feature scope reviewed for Oath 5.0.2 (104) on 2026-11-06. Screens show Oath 4.0.3; appearance can differ in newer versions.

[Release availability record](https://github.com/OathWallet/oath-wallet/blob/main/releases/5.0.2-distribution.json)

- [OathPermissionService.swift](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/OathAtmosphere/Permissions/OathPermissionService.swift)
- [Permissions.swift](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/Packages/OathAnkr/Sources/OathAnkr/Permissions.swift)
- [PermissionDiscovery.swift](https://github.com/OathWallet/oath-wallet/blob/7ffd0f449c3312d9fafd01eda59c6b9eb813f9ca/Packages/OathAnkr/Sources/OathAnkr/PermissionDiscovery.swift)

Source review and sample screens do not establish a completed live transaction or backup.

## More Oath features

- [Encrypted iCloud wallet backup](https://oathwallet.org/features/icloud-wallet-backup)
- [Connect to dApps with WalletConnect](https://oathwallet.org/features/walletconnect)

[All features](https://oathwallet.org/features)

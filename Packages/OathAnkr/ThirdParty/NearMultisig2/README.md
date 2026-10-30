# NEAR multisig2 contract

Upstream: https://github.com/near/core-contracts
Pinned commit: `1b0436c96379c63aee7d2429c6d5d24019031ab8`
Artifact: `multisig2/res/multisig2.wasm` from that commit, copied without modification to `Sources/OathAnkr/Resources/NearMultisig2.wasm`.
SHA-256: `f3f9ee3e5e29d020dc73f581ff1490c03dff875ed01327dfebbe666724930a76`

The runtime verifies the artifact digest and the deployed code hash. It verifies all members, the threshold, restricted access-key receiver/methods, and absence of full-access keys before approving transfers. Deployment uses a separate random bootstrap key; a second authenticated transaction removes it only after on-chain contract and member verification. Both networks use identical contract bytes and signing rules.

Only Ed25519 access-key members and NEAR/NEP-141 payments are exposed. Membership changes, upgrades, arbitrary calls and external co-signing are not exposed by this feature. All member secrets are stored in the existing encrypted local vault, as with Oath's other multisig creation flows.

This is an upstream artifact, not a claim that Oath rebuilt or independently audited the contract.

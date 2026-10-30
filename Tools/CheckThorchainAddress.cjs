// Host-only derivation check using WalletCore 4.8.4, the app's pinned version.
// Run with WALLET_CORE_NODE_MODULE=/path/to/@trustwallet/wallet-core node this-file.
// The zero-entropy BIP39 vector is public test data. Never fund this address.
const assert = require('node:assert/strict');
const { initWasm } = require(process.env.WALLET_CORE_NODE_MODULE || '@trustwallet/wallet-core');
(async () => {
  const core = await initWasm();
  const wallet = core.HDWallet.createWithMnemonic([...Array(11).fill('abandon'), 'about'].join(' '), '');
  const key = wallet.getKey(core.CoinType.thorchain, "m/44'/931'/0'/0/0");
  try {
    const expected = 'thor1gm00vwsfcp48enm4uv9e5dhm37jtd0ye27wrx0';
    assert.equal(wallet.getAddressForCoin(core.CoinType.thorchain), expected);
    assert.equal(core.CoinTypeExt.deriveAddress(core.CoinType.thorchain, key), expected);
    assert(core.AnyAddress.isValid(expected, core.CoinType.thorchain));
    assert(!core.AnyAddress.isValid(expected.slice(0, -1) + 'q', core.CoinType.thorchain));
    console.log('THORChain default derivation, explicit BIP44 path, private-key address and checksum passed. Public vector only.');
  } finally { key.delete(); wallet.delete(); }
})().catch(() => { console.error('THORChain derivation check failed'); process.exitCode = 1; });

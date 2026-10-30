// Real relay requests -> production Swift review/signing -> isolated THORNode.
// Requires an explicitly funded disposable local fixture, never an app wallet.
process.env.DISABLE_GLOBAL_CORE = 'true';
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const assert = require('node:assert/strict');
const { SignClient } = require('@walletconnect/sign-client');
const load = createRequire(path.resolve(process.env.COSMJS_NODE_MODULE, '../package.json'));
const { makeAuthInfoBytes } = load('@cosmjs/proto-signing');
const { fromBech32 } = load('@cosmjs/encoding');
const { TxBody, TxRaw } = load('cosmjs-types/cosmos/tx/v1beta1/tx');
const { PubKey } = load('cosmjs-types/cosmos/crypto/secp256k1/keys');
const chainID = 'oath-thorchain-test-1', chainId = 'cosmos:' + chainID;
const api = 'http://127.0.0.1:28317', rpcURL = 'http://127.0.0.1:28657';
let stage = 'configuration';
for (const name of ['log', 'info', 'warn', 'error', 'debug']) console[name] = () => {};
const timer = setTimeout(() => fail('timeout'), 180000);
function fail(reason) { process.stdout.write(`FAIL: local THORChain relay ${reason} at ${stage}.\n`); process.exit(1); }
function memory() { const v = new Map(); return { getKeys: async () => [...v.keys()], getEntries: async () => [...v.entries()], getItem: async k => v.get(k), setItem: async (k,x) => { v.set(k,x); }, removeItem: async k => { v.delete(k); } }; }
const b64 = bytes => Buffer.from(bytes).toString('base64');
const varint = value => { let n = BigInt(value); const b = []; do { const v = Number(n & 127n); n >>= 7n; b.push(v | (n ? 128 : 0)); } while (n); return Buffer.from(b); };
const field = (tag, value) => { const b = Buffer.from(value); return Buffer.concat([varint(tag * 8 + 2), varint(b.length), b]); };
async function read(url, options) { const r = await fetch(url, { ...options, signal: AbortSignal.timeout(10000) }); assert.equal(r.status, 200); return r.json(); }
async function rpc(method, params) { return read(rpcURL, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) }); }
async function balances(owner) {
  const r = await read(api + '/cosmos/bank/v1beta1/balances/' + owner);
  return Object.fromEntries(r.balances.map(c => [c.denom, BigInt(c.amount)]));
}
function bridge(request) {
  const result = spawnSync(process.env.OATH_THORCHAIN_WC_BRIDGE, [], { input: JSON.stringify(request), encoding: 'utf8', timeout: 20000 });
  return result.status === 0 ? JSON.parse(result.stdout) : null;
}
(async () => {
  // Use the website's SDK for deposit construction as well as an independent
  // Cosmos encoder, so hand-built fixtures cannot conceal an SDK mismatch.
  const sdkRoot = process.env.TCSWAP_NODE_MODULE;
  assert.ok(sdkRoot, 'TCSWAP_NODE_MODULE must contain the website SDK');
  const sdk = await import(pathToFileURL(path.join(sdkRoot, '@tcswap/toolboxes/dist/cosmos/index.js')));
  const { AssetValue, Chain } = await import(pathToFileURL(path.join(sdkRoot, '@tcswap/helpers/dist/index.js')));
  const { sender, recipient, publicKey } = JSON.parse(fs.readFileSync(process.env.OATH_THORCHAIN_SEND_FIXTURE, 'utf8'));
  const key = Buffer.from(publicKey, 'hex');
  assert.equal((await rpc('status', {})).result.node_info.network, chainID);
  const metadata = name => ({ name, description: 'Isolated local THORChain test', url: 'https://oathwallet.org', icons: [] });
  const options = name => ({ projectId: process.env.OATH_WC_PROJECT_ID, metadata: metadata(name), logger: 'silent', storage: memory(), customStoragePrefix: randomUUID() });
  const [peer, wallet] = await Promise.all([SignClient.init(options('Oath local-chain dApp')), SignClient.init(options('Oath local-chain signer'))]);
  const methods = ['cosmos_getAccounts', 'cosmos_signAmino', 'cosmos_signDirect'];
  stage = 'pairing';
  const proposal = new Promise(resolve => wallet.once('session_proposal', resolve));
  const { uri, approval } = await peer.connect({ requiredNamespaces: { cosmos: { chains: [chainId], methods, events: [] } } });
  await wallet.pair({ uri });
  const p = await proposal;
  const approved = await wallet.approve({ id: p.id, namespaces: { cosmos: { chains: [chainId], accounts: [chainId + ':' + sender], methods, events: [] } } });
  await approved.acknowledged();
  const session = await approval();
  async function request(method, params, rejected = false) {
    const incoming = new Promise(resolve => wallet.once('session_request', resolve));
    // Attach a rejection handler before responding with an expected error.
    const pending = peer.request({ topic: session.topic, chainId, request: { method, params } }).then(result => ({ result }), error => ({ error }));
    const delivered = await incoming;
    assert.equal(delivered.params.chainId, chainId);
    const result = bridge({ ...delivered.params.request, chainId });
    if (rejected) assert.equal(result, null);
    else assert.notEqual(result, null);
    const response = result === null ? { error: { code: 4001, message: 'Request rejected' } } : { result };
    await wallet.respond({ topic: delivered.topic, response: { id: delivered.id, jsonrpc: '2.0', ...response } });
    const returned = await pending;
    if (rejected) assert.equal(returned.error?.code, 4001);
    else assert.deepEqual(returned.result, result);
    return result;
  }
  assert.deepEqual(await request('cosmos_getAccounts', {}), [{ address: sender, algo: 'secp256k1', pubkey: b64(key) }]);
  const evidence = [];
  let rejected = 0;
  for (const method of ['cosmos_signAmino', 'cosmos_signDirect']) {
    for (const kind of ['rune', 'tcy', 'x/ruji', 'x/oath-test', 'deposit']) {
      stage = method + '/' + kind;
      const deposit = kind === 'deposit', denom = deposit ? 'rune' : kind, amount = '123456';
      const [account, network, senderBefore, recipientBefore] = await Promise.all([
        read(api + '/cosmos/auth/v1beta1/accounts/' + sender).then(x => x.account),
        read(api + '/thorchain/network'), balances(sender), balances(recipient)
      ]);
      const memo = deposit ? 'RESERVE' : 'Oath <&> / é اختبار';
      const coin = Buffer.concat([field(1, denom), field(2, amount)]);
      const asset = Buffer.concat([field(1, 'THOR'), field(2, 'RUNE'), field(3, 'RUNE')]);
      const bodyMessage = deposit ? Buffer.concat([field(1, Buffer.concat([field(1, asset), field(2, amount)])), field(2, 'RESERVE'), field(3, fromBech32(sender).data)])
        : Buffer.concat([field(1, fromBech32(sender).data), field(2, fromBech32(recipient).data), field(3, coin)]);
      let body = TxBody.encode(TxBody.fromPartial({ messages: [{ typeUrl: deposit ? '/types.MsgDeposit' : '/types.MsgSend', value: bodyMessage }], memo })).finish();
      const gas = deposit ? Number(sdk.getDefaultChainFee(Chain.THORChain).gas) : 6000000;
      const auth = makeAuthInfoBytes([{ pubkey: { typeUrl: '/cosmos.crypto.secp256k1.PubKey', value: PubKey.encode({ key }).finish() }, sequence: Number(account.sequence) }], [], gas, undefined, undefined, method === 'cosmos_signAmino' ? 127 : 1);
      const msg = deposit ? sdk.buildAminoMsg({ sender, memo, assetValue: AssetValue.from({ asset: 'THOR.RUNE', value: '0.00123456' }) })
        : { type: 'thorchain/MsgSend', value: { from_address: sender, to_address: recipient, amount: [{ denom, amount }] } };
      if (deposit) {
        assert.equal(msg.value.coins[0].amount, amount);
        const sdkBody = await sdk.buildEncodedTxBody({ chain: Chain.THORChain, memo, msgs: [sdk.parseAminoMessageForDirectSigning(msg)] });
        assert.deepEqual(Buffer.from(sdkBody), Buffer.from(body));
        body = sdkBody;
      }
      const signDoc = method === 'cosmos_signAmino' ? { chain_id: chainID, account_number: account.account_number, sequence: account.sequence, fee: { amount: [], gas: String(gas) }, msgs: [msg], memo }
        : { chainId: chainID, accountNumber: account.account_number, bodyBytes: b64(body), authInfoBytes: b64(auth) };
      const params = { signerAddress: sender, signDoc };
      if (kind === 'rune' || kind === 'x/oath-test') {
        stage += '/insufficient-balance';
        // RUNE must also cover the protocol fee; token units cannot exceed
        // holdings even when the wallet has enough RUNE for that fee.
        const tooMuch = String(senderBefore[denom] + (kind === 'rune' ? 0n : 1n));
        const badMessage = Buffer.concat([field(1, fromBech32(sender).data), field(2, fromBech32(recipient).data), field(3, Buffer.concat([field(1, denom), field(2, tooMuch)]))]);
        const badBody = TxBody.encode(TxBody.fromPartial({ messages: [{ typeUrl: '/types.MsgSend', value: badMessage }], memo })).finish();
        const badDoc = method === 'cosmos_signAmino' ? { ...signDoc, msgs: [{ ...msg, value: { ...msg.value, amount: [{ denom, amount: tooMuch }] } }] }
          : { ...signDoc, bodyBytes: b64(badBody) };
        await request(method, { ...params, signDoc: badDoc }, true); rejected++;
        stage = method + '/' + kind;
      }
      if (kind === 'rune') {
        stage += '/wrong-network';
        await request(method, { ...params, signDoc: { ...signDoc, [method === 'cosmos_signAmino' ? 'chain_id' : 'chainId']: 'thorchain-1' } }, true); rejected++;
        stage = method + '/' + kind;
      }
      const signed = await request(method, params);
      assert.deepEqual(signed.signed, signDoc);
      assert.equal(signed.signature.pub_key.value, b64(key));
      const tx = TxRaw.encode({ bodyBytes: body, authInfoBytes: auth, signatures: [Buffer.from(signed.signature.signature, 'base64')] }).finish();
      const sent = (await rpc('broadcast_tx_sync', { tx: b64(tx) })).result;
      assert.equal(sent.code, 0);
      let receipt;
      for (let i = 0; i < 25; i++) {
        await new Promise(resolve => setTimeout(resolve, 1000));
        receipt = (await rpc('tx', { hash: b64(Buffer.from(sent.hash, 'hex')) })).result;
        if (receipt?.height) break;
      }
      assert.equal(receipt?.tx_result?.code, 0);
      const [senderAfter, recipientAfter] = await Promise.all([balances(sender), balances(recipient)]);
      const fee = BigInt(network.native_tx_fee_rune), value = BigInt(amount);
      assert.equal(senderBefore.rune - senderAfter.rune, fee + (denom === 'rune' ? value : 0n));
      assert.equal(senderBefore[denom] - senderAfter[denom], value + (denom === 'rune' ? fee : 0n));
      assert.equal((recipientAfter[denom] || 0n) - (recipientBefore[denom] || 0n), deposit ? 0n : value);
      if (kind === 'rune') {
        stage += '/stale-sequence';
        await request(method, params, true); rejected++;
      }
      evidence.push({ method, kind, hash: sent.hash, height: receipt.height, fee: String(fee), amount, balanceDeltasVerified: true });
      process.stdout.write(`Confirmed local relay transaction: ${method} ${kind}.\n`);
    }
  }
  stage = 'disconnect';
  const deleted = new Promise(resolve => peer.once('session_delete', resolve));
  await wallet.disconnect({ topic: session.topic, reason: { code: 6000, message: 'Test complete' } }); await deleted;
  assert.equal(peer.session.getAll().length, 0); assert.equal(wallet.session.getAll().length, 0);
  fs.writeFileSync('/tmp/oath-thor-wc-node-relay-evidence.json', JSON.stringify({ chainID, rejected, transactions: evidence }, null, 2) + '\n');
  clearTimeout(timer);
  process.stdout.write(`PASS: ${evidence.length} local-chain transactions through live relay and production Swift review/signing; ${rejected} insufficient-balance/wrong-network/stale-sequence requests rejected. Native iOS UI and public stagenet not exercised.\n`);
  process.exit(0);
})().catch(() => { clearTimeout(timer); fail('check'); });

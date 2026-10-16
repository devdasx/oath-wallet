// Explicit opt-in isolated JS relay peers. Uses production Swift signing/RPC,
// never launches iOS and never sends on mainnet. No SDK log or pairing URI output.
process.env.DISABLE_GLOBAL_CORE = 'true';
const fs = require('node:fs'), cp = require('node:child_process'), crypto = require('node:crypto');
const assert = require('node:assert/strict'), { SignClient } = require('@walletconnect/sign-client');
const w = require('@solana/web3.js'), b58 = require('bs58'), base58 = b58.default || b58;
for (const name of ['log', 'warn', 'info', 'debug', 'error']) console[name] = () => {};
const keyFile = process.env.OATH_SOLANA_TESTNET_FIXTURE, bridgePath = process.env.OATH_WC_SOLANA_BRIDGE;
const chains = { devnet: 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1', testnet: 'solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z' };
const methods = ['solana_getAccounts', 'solana_requestAccounts', 'solana_signMessage', 'solana_signTransaction', 'solana_signAllTransactions', 'solana_signAndSendTransaction'];
let stage = 'configuration';
const timer = setTimeout(() => { process.stdout.write('FAIL Solana relay timeout at ' + stage + '\n'); process.exit(1); }, 180000);
function memory() { const values = new Map(); return { getKeys: async () => [...values.keys()], getEntries: async () => [...values.entries()], getItem: async k => values.get(k), setItem: async (k, v) => { values.set(k, v); }, removeItem: async k => { values.delete(k); } }; }
function bridge(chain, request) {
  return new Promise((resolve, reject) => {
    const p = cp.spawn(bridgePath, [], { stdio: ['pipe', 'pipe', 'pipe'] }); let output = '';
    p.stdout.on('data', bytes => { output += bytes; }); p.stderr.resume();
    p.on('error', () => reject(Error('bridge launch')));
    p.on('close', code => { if (code) reject(Error('bridge failure')); else { try { resolve(JSON.parse(output)); } catch { reject(Error('bridge response')); } } });
    p.stdin.end(JSON.stringify({ keyFile, chain, ...request }));
  });
}
async function run() {
  assert(keyFile && bridgePath && /^[a-f0-9]{32}$/i.test(process.env.OATH_WC_PROJECT_ID || ''));
  const fixture = JSON.parse(fs.readFileSync(keyFile)); assert.equal(fixture.network, 'devnet');
  const owner = new w.PublicKey(fixture.sender), recipient = new w.PublicKey(fixture.recipient);
  const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), owner.toBuffer()]), format: 'der', type: 'spki' });
  const metadata = name => ({ name, description: 'Isolated Solana test-cluster compatibility', url: 'https://oathwallet.org', icons: [] });
  const config = name => ({ projectId: process.env.OATH_WC_PROJECT_ID, metadata: metadata(name), logger: 'silent', storage: memory(), customStoragePrefix: crypto.randomUUID() });
  const peer = await SignClient.init(config('Oath Solana test dApp')), wallet = await SignClient.init(config('Oath Solana test signer'));
  stage = 'pairing';
  const proposed = new Promise(resolve => wallet.once('session_proposal', resolve));
  const { uri, approval } = await peer.connect({ requiredNamespaces: { solana: { chains: Object.values(chains), methods, events: [] } } });
  await wallet.pair({ uri }); const proposal = await proposed;
  const approved = await wallet.approve({ id: proposal.id, namespaces: { solana: { chains: Object.values(chains), accounts: Object.values(chains).map(c => c + ':' + fixture.sender), methods, events: [] } } });
  await approved.acknowledged(); const session = await approval();
  const report = [{ check: 'devnet-testnet-session', verified: true }];
  async function request(method, params, chain = chains.devnet) {
    stage = method;
    const incoming = new Promise(resolve => wallet.once('session_request', resolve));
    const pending = peer.request({ topic: session.topic, chainId: chain, request: { method, params } });
    const delivered = await incoming; assert.equal(delivered.params.chainId, chain);
    let result;
    if (method.endsWith('Accounts')) result = [{ pubkey: fixture.sender }];
    else { const output = await bridge(chain, delivered.params.request); result = method === 'solana_signAndSendTransaction' ? { signature: output.signature } : output.result; }
    await wallet.respond({ topic: delivered.topic, response: { id: delivered.id, jsonrpc: '2.0', result } });
    return await pending;
  }
  for (const method of methods.slice(0, 2)) assert.deepEqual(await request(method, {}), [{ pubkey: fixture.sender }]);
  report.push({ check: 'account-discovery', verified: true });
  for (const chain of Object.values(chains)) {
    const text = Buffer.from('Oath WalletConnect isolated relay sign-in');
    const signed = await request('solana_signMessage', { pubkey: fixture.sender, message: base58.encode(text) }, chain);
    assert(crypto.verify(null, text, key, Buffer.from(base58.decode(signed.signature))));
  }
  report.push({ check: 'cluster-switch-and-message-signatures', verified: true });
  const connection = new w.Connection('https://api.devnet.solana.com', 'confirmed');
  async function transaction(versioned) {
    const { blockhash } = await connection.getLatestBlockhash();
    const instruction = w.SystemProgram.transfer({ fromPubkey: owner, toPubkey: recipient, lamports: 1000 });
    const tx = versioned ? new w.VersionedTransaction(new w.TransactionMessage({ payerKey: owner, recentBlockhash: blockhash, instructions: [instruction] }).compileToV0Message()) : new w.Transaction({ feePayer: owner, recentBlockhash: blockhash }).add(instruction);
    return Buffer.from(tx.serialize({ requireAllSignatures: false, verifySignatures: false })).toString('base64');
  }
  function verify(signed, original) {
    const tx = w.VersionedTransaction.deserialize(Buffer.from(signed, 'base64'));
    const old = w.VersionedTransaction.deserialize(Buffer.from(original, 'base64'));
    assert.deepEqual(tx.message.serialize(), old.message.serialize());
    assert(crypto.verify(null, Buffer.from(tx.message.serialize()), key, Buffer.from(tx.signatures[0])));
  }
  const single = await transaction(true), signed = await request('solana_signTransaction', { transaction: single, pubkey: fixture.sender });
  verify(signed.transaction, single); report.push({ check: 'sign-versioned-transaction', verified: true });
  await new Promise(resolve => setTimeout(resolve, 12000));
  const batch = [await transaction(false), await transaction(true)];
  const all = await request('solana_signAllTransactions', { transactions: batch });
  assert.equal(all.transactions.length, batch.length); all.transactions.forEach((tx, i) => verify(tx, batch[i]));
  report.push({ check: 'sign-ordered-legacy-versioned-batch', verified: true });
  await new Promise(resolve => setTimeout(resolve, 12000));
  const before = await connection.getBalance(recipient), tx = await transaction(true);
  const sent = await request('solana_signAndSendTransaction', { transaction: tx });
  assert.equal((await connection.getBalance(recipient)) - before, 1000);
  report.push({ check: 'sign-send-confirm-through-relay', network: 'devnet', signature: sent.signature, receivedAtomic: '1000', verified: true });
  stage = 'disconnect'; const deleted = new Promise(resolve => peer.once('session_delete', resolve));
  await wallet.disconnect({ topic: session.topic, reason: { code: 6000, message: 'Test complete' } }); await deleted;
  assert.equal(wallet.session.getAll().length, 0); assert.equal(peer.session.getAll().length, 0);
  report.push({ check: 'disconnect', verified: true });
  fs.mkdirSync('output', { recursive: true });
  fs.writeFileSync('output/walletconnect-solana-relay.json', JSON.stringify({ testedAt: new Date().toISOString(), layer: 'isolated JS relay peers with production Swift protocol/signing/RPC; no native iOS session/UI', checks: report }, null, 2) + '\n');
  clearTimeout(timer); process.stdout.write('PASS Solana live relay: six methods, devnet/testnet switching, independent signature checks, confirmed devnet transfer and disconnect. Native iOS UI not exercised.\n'); process.exit(0);
}
run().catch(() => { clearTimeout(timer); process.stdout.write('FAIL Solana relay at ' + stage + '; native iOS UI not exercised.\n'); process.exit(1); });

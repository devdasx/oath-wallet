/* Optional live protocol smoke test. Two isolated peers, public scalar-1 key,
 * in-memory storage, no wallet/app data, no on-chain transaction. Requires
 * @walletconnect/sign-client and ethers in NODE_PATH and OATH_WC_PROJECT_ID.
 * Fixed-only output prevents a relay error from exposing a pairing URI/token. */
process.env.DISABLE_GLOBAL_CORE = 'true';
const { randomUUID } = require('node:crypto');
const { SignClient } = require('@walletconnect/sign-client');
const { Wallet, verifyMessage } = require('ethers');
for (const method of ['log', 'info', 'warn', 'error', 'debug']) console[method] = () => {};
let stage = 'initialization';
const timeout = setTimeout(() => { process.stdout.write('Relay smoke test timed out at ' + stage + '.\n'); process.exit(1); }, 55000);
function memory() {
  const values = new Map();
  return { getKeys: async () => [...values.keys()], getEntries: async () => [...values.entries()],
    getItem: async k => values.get(k), setItem: async (k,v) => {values.set(k,v);}, removeItem: async k => {values.delete(k);} };
}
(async () => {
  const projectId = process.env.OATH_WC_PROJECT_ID;
  if (!/^[a-f0-9]{32}$/i.test(projectId || '')) throw Error('configuration');
  const metadata = name => ({name, description:'Isolated Oath scanner protocol check', url:'https://oathwallet.org',icons:['https://oathwallet.org/wallet-logo.png']});
  const dapp = await SignClient.init({ projectId, metadata:metadata('Oath test peer'), customStoragePrefix:'oath-peer-'+randomUUID(), logger:'silent', storage:memory() });
  stage = 'wallet relay initialization';
  const wallet = await SignClient.init({ projectId, metadata:metadata('Oath test wallet'), customStoragePrefix:'oath-wallet-'+randomUUID(), logger:'silent', storage:memory() });
  const key = new Wallet('0x' + '00'.repeat(31) + '01'); // Public test vector, never funded.
  const proposal = new Promise(resolve => wallet.once('session_proposal', resolve));
  stage = 'dapp proposal publication';
  const {uri, approval} = await dapp.connect({requiredNamespaces:{eip155:{chains:['eip155:1'],methods:['personal_sign','eth_accounts','eth_chainId'],events:['accountsChanged','chainChanged']}}});
  stage = 'wallet pairing subscription';
  await wallet.pair({uri});
  stage = 'proposal delivery';
  const event = await proposal;
  const approved = await wallet.approve({id:event.id,namespaces:{eip155:{chains:['eip155:1'],accounts:['eip155:1:'+key.address],methods:['personal_sign','eth_accounts','eth_chainId'],events:['accountsChanged','chainChanged']}}});
  stage = 'session settlement';
  await approved.acknowledged();
  const session = await approval();
  stage = 'session metadata';
  const savedPeer = wallet.session.get(session.topic).peer.metadata;
  if (savedPeer.name !== 'Oath test peer' || savedPeer.icons[0] !== 'https://oathwallet.org/wallet-logo.png') throw Error('metadata');
  stage = 'message round trip';
  const incoming = new Promise(resolve => wallet.once('session_request', resolve));
  const response = dapp.request({topic:session.topic,chainId:'eip155:1',request:{method:'personal_sign',params:['0x4f617468207363616e6e65722074657374',key.address]}});
  const request = await incoming;
  const bytes = Buffer.from(request.params.request.params[0].slice(2),'hex');
  const signature = await key.signMessage(bytes);
  await wallet.respond({topic:request.topic,response:{id:request.id,jsonrpc:'2.0',result:signature}});
  if (verifyMessage(bytes, await response) !== key.address) throw Error('signature');
  stage = 'peer disconnect';
  const deleted = new Promise(resolve => dapp.once('session_delete', resolve));
  await wallet.disconnect({topic:session.topic,reason:{code:6000,message:'Test complete'}});
  await deleted;
  if (wallet.session.getAll().some(item => item.topic === session.topic) || dapp.session.getAll().some(item => item.topic === session.topic)) throw Error('disconnect');
  clearTimeout(timeout);
  process.stdout.write('PASS: project relay authentication, pairing, namespace approval, dApp metadata/logo preservation, personal_sign round trip, verification and both-peer disconnect. Isolated JS peers only; native iOS pairing is not covered.\n');
  process.exit(0);
})().catch(() => { clearTimeout(timeout); process.stdout.write('FAIL: isolated relay protocol check; native iOS pairing remains unverified.\n'); process.exit(1); });

#!/usr/bin/env node
// Read-only mainnet request-stage benchmark. No wallet keys or broadcast methods.
// Compare alternating schedules to reduce connection warm-up/order bias.
const proxy = 'https://aperture-notifications.devdas98x.workers.dev/v1/provider/ankr';
const endpoints = {
  eth: 'https://ethereum-rpc.publicnode.com',
  near: `${proxy}/near/jsonrpc`,
  solana: 'https://api.mainnet-beta.solana.com',
};
let requestID = 0;
async function rpc(chain, method, params) {
  const started = performance.now();
  const response = await fetch(endpoints[chain], {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++requestID, method, params }),
    signal: AbortSignal.timeout(20_000),
  });
  const body = await response.json();
  if (!response.ok || body.error) {
    throw Error(`${chain}/${method}: HTTP ${response.status} ${JSON.stringify(body.error)}`);
  }
  return { ms: Math.round(performance.now() - started), result: body.result };
}
const address = '0x000000000000000000000000000000000000dEaD';
const usdc = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const jobs = {
  evm: [
    () => rpc('eth', 'eth_call', [{ to: usdc, data: '0x313ce567' }, 'latest']),
    () => Promise.all([
      rpc('eth', 'eth_chainId', []),
      rpc('eth', 'eth_getTransactionCount', [address, 'pending']),
      rpc('eth', 'eth_getBalance', [address, 'pending']),
      rpc('eth', 'eth_estimateGas', [{ from: address, to: address, value: '0x0' }]),
      rpc('eth', 'eth_call', [{ to: usdc, data: '0x70a08231' + address.slice(2).toLowerCase().padStart(64, '0') }, 'latest']),
    ]),
  ],
  near: [
    () => Promise.all([
      rpc('near', 'query', { request_type: 'view_account', finality: 'final', account_id: 'wrap.near' }),
      rpc('near', 'EXPERIMENTAL_protocol_config', { finality: 'final' }),
    ]),
    () => Promise.all(['ft_balance_of', 'storage_balance_of'].map(method_name => rpc('near', 'query', {
      request_type: 'call_function', finality: 'final', account_id: 'wrap.near', method_name,
      args_base64: Buffer.from(JSON.stringify({ account_id: 'wrap.near' })).toString('base64'),
    }))),
  ],
};
function decodeBlockhash(text) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let value = 0n;
  for (const character of text) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) throw Error('Invalid blockhash');
    value = value * 58n + BigInt(digit);
  }
  const bytes = Buffer.from(value.toString(16).padStart(64, '0'), 'hex');
  if (bytes.length !== 32) throw Error('Invalid blockhash length');
  return bytes;
}
const samples = [];
try {
  const latest = await rpc('solana', 'getLatestBlockhash', [{ commitment: 'confirmed' }]);
  // A serialized unsigned legacy message for fee calculation only.
  const message = Buffer.concat([
    Buffer.from([1, 0, 1, 2]), Buffer.alloc(32, 1), Buffer.alloc(32),
    decodeBlockhash(latest.result.value.blockhash),
    Buffer.from([1, 1, 2, 0, 0, 12, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]),
  ]).toString('base64');
  jobs.solana = [
    () => rpc('solana', 'getFeeForMessage', [message, { commitment: 'confirmed' }]),
    () => Promise.all([
      rpc('solana', 'getMinimumBalanceForRentExemption', [0, { commitment: 'confirmed' }]),
      rpc('solana', 'getAccountInfo', ['11111111111111111111111111111111', { encoding: 'base64', commitment: 'confirmed' }]),
    ]),
  ];
} catch (error) {
  samples.push({ chain: 'solana', error: error.message });
  process.exitCode = 1;
}
for (const [chain, stages] of Object.entries(jobs)) {
  for (let round = 0; round < 3; round++) {
    for (const parallel of round % 2 ? [true, false] : [false, true]) {
      const start = performance.now();
      try {
        const results = parallel ? await Promise.all(stages.map(run => run())) : [await stages[0](), await stages[1]()];
        if (chain === 'solana' && !(results[0].result.value > 0)) throw Error('Message fee unavailable');
        samples.push({ chain, round, parallel, elapsedMS: Math.round(performance.now() - start), requests: results.flat().map(value => value.ms) });
      } catch (error) {
        samples.push({ chain, round, parallel, error: error.message });
        process.exitCode = 1;
      }
    }
  }
}
console.log(JSON.stringify(samples, null, 2));

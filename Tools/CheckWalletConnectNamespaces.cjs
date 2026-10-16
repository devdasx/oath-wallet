// Validate actual Swift-built synthetic namespaces with the same WalletConnect
// JS request validator used by the browser. No client, connection or transaction.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { isValidNamespacesRequest } = require('@walletconnect/utils');
const { legacy, fixed } = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(isValidNamespacesRequest(legacy, 'eip155:1', 'eth_sendTransaction'), false);
for (const chain of ['eip155:1', 'eip155:42161']) {
  assert.equal(isValidNamespacesRequest(fixed, chain, 'eth_sendTransaction'), true);
  assert.equal(isValidNamespacesRequest(fixed, chain, 'personal_sign'), true);
  assert.equal(isValidNamespacesRequest(fixed, chain, 'wallet_sendCalls'), false);
  assert.equal(isValidNamespacesRequest(fixed, chain, 'cosmos_signDirect'), false);
}
assert.equal(isValidNamespacesRequest(fixed, 'eip155:5042', 'eth_sendTransaction'), false);
assert.equal(isValidNamespacesRequest(fixed, 'eip155:8453', 'eth_sendTransaction'), false);
console.log('Browser request validator: original failure reproduced; fixed Ethereum/Arbitrum accepted; unsupported and unapproved requests rejected.');

const solana = JSON.parse(fs.readFileSync(process.argv[2] + '.solana', 'utf8'));
const clusters = ['solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp', 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1', 'solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z'];
for (const chain of clusters) {
  for (const method of ['solana_signMessage', 'solana_signTransaction', 'solana_signAllTransactions', 'solana_signAndSendTransaction']) {
    assert.equal(isValidNamespacesRequest(solana.all, chain, method), true);
  }
  assert.equal(isValidNamespacesRequest(solana.all, chain, 'eth_sendTransaction'), false);
  assert.equal(isValidNamespacesRequest(solana.devnet, chain, 'solana_signTransaction'), chain === clusters[1]);
  assert.equal(isValidNamespacesRequest(solana.devnet, chain, 'solana_signAndSendTransaction'), false);
}
console.log('Browser request validator: all three Solana clusters accepted only when approved; unapproved clusters and cross-namespace methods rejected.');

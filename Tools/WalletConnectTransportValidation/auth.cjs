// Ephemeral identities for the optional native relay test. Output is consumed
// privately by the runner, never written to logs or persisted.
const { generateKeyPair, signJWT } = require('@walletconnect/relay-auth');
const { randomUUID } = require('node:crypto');
(async () => {
  const tokens = await Promise.all([0, 1].map(() => signJWT(randomUUID(),
    'wss://relay.walletconnect.com', 300, generateKeyPair())));
  process.stdout.write(JSON.stringify({ projectID: process.env.OATH_WC_PROJECT_ID, tokens }));
})().catch(() => { process.stderr.write('Relay fixture authentication failed.\n'); process.exit(1); });

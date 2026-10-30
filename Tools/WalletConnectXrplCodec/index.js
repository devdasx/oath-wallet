import 'fast-text-encoding';
import { encode, decode, encodeForSigning, encodeForMultisigning } from 'ripple-binary-codec';
import { validate } from 'xrpl/dist/npm/models/transactions/transaction.js';
import { verify, deriveAddress } from 'ripple-keypairs';

// Public transaction data only. Private keys and signing never enter this runtime.
export function run(input) {
  const { tx, signer } = JSON.parse(input);
  validate(tx);
  const bytes = encode(tx), canonical = decode(bytes);
  function preserved(a, b) {
    if (a === null || typeof a !== 'object') {
      if (typeof a === 'number' && !Number.isSafeInteger(a)) throw Error('number');
      if (a !== b) throw Error('roundtrip');
      return;
    }
    if (!b || Array.isArray(a) !== Array.isArray(b)) throw Error('roundtrip');
    for (const k of Object.keys(a)) {
      if (!(k in b)) throw Error('field');
      preserved(a[k], b[k]);
    }
  }
  preserved(tx, canonical);
  if (tx.Signers) {
    const seen = new Set();
    for (const { Signer: s } of tx.Signers) {
      if (seen.has(s.Account) || deriveAddress(s.SigningPubKey) !== s.Account ||
          !verify(encodeForMultisigning(tx, s.Account), s.TxnSignature, s.SigningPubKey)) throw Error('signature');
      seen.add(s.Account);
    }
  }
  return JSON.stringify({ bytes, transaction: canonical,
    signing: signer ? encodeForMultisigning(tx, signer) : encodeForSigning(tx) });
}

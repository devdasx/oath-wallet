// Independent SDK vectors. Fixed public test seeds, never app wallet material.
const fs=require('fs'), w=require('@solana/web3.js');
const signer=w.Keypair.fromSeed(Buffer.alloc(32,1)), other=w.Keypair.fromSeed(Buffer.alloc(32,2));
const recipient=w.Keypair.fromSeed(Buffer.alloc(32,3)).publicKey;
const blockhash=w.Keypair.fromSeed(Buffer.alloc(32,4)).publicKey.toBase58();
const ix=w.SystemProgram.transfer({fromPubkey:signer.publicKey,toPubkey:recipient,lamports:12345});
function vector(name, tx) {
  let unsigned=tx.serialize({requireAllSignatures:false,verifySignatures:false});
  if(tx instanceof w.VersionedTransaction)tx.sign([signer]);else tx.partialSign(signer);
  return {name,account:signer.publicKey.toBase58(),unsigned:Buffer.from(unsigned).toString('base64'),signed:Buffer.from(tx.serialize({requireAllSignatures:false,verifySignatures:false})).toString('base64')};
}
const legacy=new w.Transaction({feePayer:signer.publicKey,recentBlockhash:blockhash}).add(ix);
const lookup=new w.AddressLookupTableAccount({key:other.publicKey,state:{deactivationSlot:18446744073709551615n,lastExtendedSlot:1,lastExtendedSlotStartIndex:0,authority:signer.publicKey,addresses:[recipient]}});
const versioned=new w.VersionedTransaction(new w.TransactionMessage({payerKey:signer.publicKey,recentBlockhash:blockhash,instructions:[ix]}).compileToV0Message([lookup]));
const multisig=new w.Transaction({feePayer:other.publicKey,recentBlockhash:blockhash}).add(ix);multisig.partialSign(other);
fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnect/solana.json',JSON.stringify({vectors:[vector('legacy',legacy),vector('v0Lookup',versioned),vector('partialMultisig',multisig)]},null,2)+'\n');
console.log('Generated 3 independent Solana transaction vectors.');
const nonce=new w.Transaction({feePayer:signer.publicKey,recentBlockhash:blockhash}).add(
  w.SystemProgram.nonceAdvance({noncePubkey:other.publicKey,authorizedPubkey:signer.publicKey}),ix);
const state=Buffer.alloc(80);state.writeUInt32LE(1,0);state.writeUInt32LE(1,4);
signer.publicKey.toBuffer().copy(state,8);new w.PublicKey(blockhash).toBuffer().copy(state,40);state.writeBigUInt64LE(5000n,72);
const nonceV0=vector('durableNonceV0',new w.VersionedTransaction(new w.TransactionMessage({
  payerKey:signer.publicKey,recentBlockhash:blockhash,instructions:nonce.instructions
}).compileToV0Message()));
fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnect/solana-nonce.json',JSON.stringify({
  ...vector('durableNonce',nonce),unsignedV0:nonceV0.unsigned,signedV0:nonceV0.signed,
  nonceAccount:other.publicKey.toBase58(),nonce:blockhash,state:state.toString('base64')
},null,2)+'\n');
